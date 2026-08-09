"""Unit tests for the hardware-independent auto-framing decisions."""

from __future__ import annotations

import unittest

from yolov8_autoframe_jetson import (
    AutoFrameController,
    CameraCommand,
    StableGroupSelector,
    TrackedObject,
    choose_best_group,
    make_decision,
)


def tracked(track_id: int, box: tuple[float, float, float, float]) -> TrackedObject:
    return TrackedObject(
        track_id=track_id,
        class_id=0,
        class_name="person",
        confidence=0.9,
        box=box,
    )


class GroupSelectionTests(unittest.TestCase):
    def test_selects_all_objects_when_the_group_fits(self) -> None:
        objects = (
            tracked(1, (200, 200, 300, 500)),
            tracked(2, (450, 210, 550, 510)),
            tracked(3, (650, 400, 730, 520)),
        )

        decision = choose_best_group(objects, 1000, 700, edge_margin=0.10)

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual({item.track_id for item in decision.objects}, {1, 2, 3})
        self.assertFalse(decision.limited_group)

    def test_selects_the_group_with_the_most_objects(self) -> None:
        objects = (
            tracked(1, (0, 20, 10, 40)),
            tracked(2, (15, 20, 25, 40)),
            tracked(3, (85, 20, 95, 40)),
        )

        decision = choose_best_group(objects, 100, 100, edge_margin=0.30)

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual({item.track_id for item in decision.objects}, {1, 2})
        self.assertTrue(decision.limited_group)

    def test_equal_count_prefers_the_group_closest_to_frame_center(self) -> None:
        objects = (
            tracked(1, (0, 40, 10, 60)),
            tracked(2, (45, 40, 55, 60)),
        )

        decision = choose_best_group(objects, 100, 100, edge_margin=0.30)

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(tuple(item.track_id for item in decision.objects), (2,))

    def test_safe_frame_selector_keeps_all_stable_people(self) -> None:
        selector = StableGroupSelector(switch_frames=1)
        decision = selector.select(
            (
                tracked(1, (0, 20, 10, 80)),
                tracked(2, (90, 20, 100, 80)),
            ),
            100,
            100,
            edge_margin=0.30,
            include_all=True,
        )

        self.assertIsNotNone(decision)
        assert decision is not None
        self.assertEqual(tuple(item.track_id for item in decision.objects), (1, 2))


class ControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.controller = AutoFrameController(
            ema_alpha=1.0,
            deadzone_width=0.12,
            deadzone_height=0.12,
            subject_y_ratio=0.35,
            home_after_seconds=5.0,
        )

    def test_target_inside_deadzone_emits_hold(self) -> None:
        decision = choose_best_group(
            (tracked(1, (45, 45, 55, 55)),),
            100,
            100,
            edge_margin=0.10,
        )

        command = self.controller.update(decision, 100, 100, now=0.0)

        self.assertEqual(command.state, "TRACKING")
        self.assertEqual(command.direction, "HOLD")
        self.assertEqual(command.command_x, "HOLD")
        self.assertEqual(command.command_y, "HOLD")

    def test_target_right_and_up_emits_combined_direction(self) -> None:
        decision = choose_best_group(
            (tracked(1, (75, 5, 85, 15)),),
            100,
            100,
            edge_margin=0.10,
        )

        command = self.controller.update(decision, 100, 100, now=0.0)

        self.assertEqual(command.direction, "RIGHT_UP")
        self.assertEqual(command.command_x, "RIGHT")
        self.assertEqual(command.command_y, "UP")
        self.assertGreater(command.error_x, 0)
        self.assertLess(command.error_y, 0)

    def test_full_height_person_tracks_upper_body_anchor(self) -> None:
        decision = choose_best_group(
            (tracked(1, (10, 0, 90, 100)),),
            100,
            100,
            edge_margin=0.10,
        )

        command = self.controller.update(decision, 100, 100, now=0.0)

        self.assertEqual(command.command_x, "HOLD")
        self.assertEqual(command.command_y, "UP")
        self.assertAlmostEqual(command.center_y, 0.35)
        self.assertAlmostEqual(command.error_y, -0.3)

    def test_holds_then_returns_home_after_target_loss(self) -> None:
        decision = choose_best_group(
            (tracked(1, (70, 45, 80, 55)),),
            100,
            100,
            edge_margin=0.10,
        )
        tracking = self.controller.update(decision, 100, 100, now=10.0)

        hold = self.controller.update(None, 100, 100, now=14.9)
        home = self.controller.update(None, 100, 100, now=15.0)

        self.assertEqual(hold.state, "NO_TARGET_HOLD")
        self.assertEqual(hold.direction, "HOLD")
        self.assertEqual(hold.command_x, "HOLD")
        self.assertEqual(hold.command_y, "HOLD")
        self.assertNotEqual(tracking.error_x, 0.0)
        self.assertEqual(hold.error_x, tracking.error_x)
        self.assertEqual(hold.error_y, tracking.error_y)
        self.assertEqual(home.state, "RETURN_HOME")
        self.assertEqual(home.direction, "HOME")
        self.assertEqual(home.command_x, "HOME")
        self.assertEqual(home.command_y, "HOME")
        self.assertEqual(home.error_x, 0.0)
        self.assertEqual(home.error_y, 0.0)


class SafeFrameControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.controller = AutoFrameController(
            ema_alpha=1.0,
            deadzone_width=0.12,
            deadzone_height=0.12,
            subject_y_ratio=0.35,
            home_after_seconds=5.0,
            tracking_mode="safe-frame",
            safe_frame_start_margin=0.08,
            safe_frame_stop_margin=0.12,
            safe_frame_edge_guard=0.04,
            target_loss_follow_seconds=0.5,
        )

    def update_box(self, box: tuple[float, float, float, float]) -> CameraCommand:
        decision = choose_best_group(
            (tracked(1, box),),
            100,
            100,
            edge_margin=0.10,
        )
        return self.controller.update(decision, 100, 100, now=0.0)

    def test_visible_person_away_from_edges_holds_without_centering(self) -> None:
        command = self.update_box((45, 22, 52, 35))

        self.assertEqual(command.direction, "HOLD")
        self.assertEqual(command.command_x, "HOLD")
        self.assertEqual(command.command_y, "HOLD")

    def full_body_controller(self) -> AutoFrameController:
        """A controller that judges whole bodies, as safe-frame once did."""

        return AutoFrameController(
            ema_alpha=1.0,
            deadzone_width=0.12,
            deadzone_height=0.12,
            subject_y_ratio=0.35,
            home_after_seconds=5.0,
            tracking_mode="safe-frame",
            safe_frame_start_margin=0.08,
            safe_frame_stop_margin=0.12,
            safe_frame_edge_guard=0.04,
            target_loss_follow_seconds=0.5,
            head_ratio=1.0,
        )

    def update_box_with(
        self,
        controller: AutoFrameController,
        box: tuple[float, float, float, float],
    ) -> CameraCommand:
        decision = choose_best_group(
            (tracked(1, box),),
            100,
            100,
            edge_margin=0.10,
        )
        return controller.update(decision, 100, 100, now=0.0)

    def test_full_body_framing_protects_the_lower_body(self) -> None:
        command = self.update_box_with(
            self.full_body_controller(),
            (20, 20, 80, 100),
        )

        self.assertEqual(command.direction, "DOWN")
        self.assertEqual(command.center_y, 0.48)

    def test_head_framing_lets_the_lower_body_leave_the_frame(self) -> None:
        command = self.update_box((20, 20, 80, 100))

        self.assertEqual(command.direction, "HOLD")

    def test_full_body_framing_freezes_on_a_frame_filling_person(self) -> None:
        # Both edges overflow at once, which reads as "no usable direction".
        # This is the stall the head slice exists to avoid.
        command = self.update_box_with(
            self.full_body_controller(),
            (10, 0, 90, 100),
        )

        self.assertEqual(command.direction, "HOLD")
        self.assertEqual(command.error_y, 0.0)

    def test_head_framing_tilts_up_for_a_frame_filling_person(self) -> None:
        command = self.update_box((10, 0, 90, 100))

        self.assertEqual(command.command_y, "UP")
        self.assertLess(command.error_y, 0.0)
        self.assertEqual(command.center_x, 0.5)
        self.assertEqual(command.center_y, 0.35)

    def test_moves_only_on_axes_whose_box_nears_an_edge(self) -> None:
        command = self.update_box((75, 2, 98, 30))

        self.assertEqual(command.direction, "RIGHT_UP")
        self.assertGreater(command.error_x, 0.0)
        self.assertLess(command.error_y, 0.0)

    def update_boxes(
        self,
        boxes: tuple[tuple[float, float, float, float], ...],
    ) -> CameraCommand:
        decision = choose_best_group(
            tuple(tracked(index, box) for index, box in enumerate(boxes, 1)),
            100,
            100,
            edge_margin=0.0,
        )
        return self.controller.update(decision, 100, 100, now=0.0)

    def test_multiple_people_hold_only_when_every_point_is_inside(self) -> None:
        command = self.update_boxes(
            (
                (20, 20, 30, 80),
                (70, 20, 80, 80),
            )
        )

        self.assertEqual(command.target_count, 2)
        self.assertEqual(command.direction, "HOLD")

    def test_moves_when_any_person_point_is_outside(self) -> None:
        command = self.update_boxes(
            (
                (4.5, 20, 9.5, 80),
                (40, 20, 50, 80),
            )
        )

        self.assertEqual(command.target_count, 2)
        self.assertEqual(command.command_x, "LEFT")

    def test_opposite_points_too_far_apart_hold_safely(self) -> None:
        command = self.update_boxes(
            (
                (4.5, 20, 9.5, 80),
                (90.5, 20, 95.5, 80),
            )
        )

        self.assertEqual(command.target_count, 2)
        self.assertEqual(command.direction, "HOLD")

    def test_multiple_people_use_their_combined_group_box(self) -> None:
        decision = choose_best_group(
            (
                tracked(1, (2, 20, 25, 80)),
                tracked(2, (40, 20, 60, 80)),
            ),
            100,
            100,
            edge_margin=0.10,
        )

        command = self.controller.update(decision, 100, 100, now=0.0)

        self.assertEqual(command.target_count, 2)
        self.assertEqual(command.command_x, "LEFT")
        self.assertEqual(command.command_y, "HOLD")

    def test_active_axis_moves_until_box_reaches_inner_stop_margin(self) -> None:
        self.assertEqual(self.update_box((3, 20, 30, 80)).command_x, "LEFT")
        self.assertEqual(self.update_box((5, 20, 32, 80)).command_x, "LEFT")
        self.assertEqual(self.update_box((8, 20, 35, 80)).command_x, "HOLD")

    def test_oversized_box_holds_instead_of_driving_into_a_limit(self) -> None:
        command = self.update_box((0, 20, 100, 80))

        self.assertEqual(command.direction, "HOLD")
        self.assertEqual(command.error_x, 0.0)
        self.assertEqual(command.error_y, 0.0)

    def test_briefly_follows_last_edge_exit_direction_after_target_loss(self) -> None:
        tracking = self.update_box((2, 20, 30, 80))
        following = self.controller.update(None, 100, 100, now=0.4)
        holding = self.controller.update(None, 100, 100, now=0.6)

        self.assertEqual(tracking.command_x, "LEFT")
        self.assertEqual(following.state, "TARGET_LOSS_FOLLOW")
        self.assertEqual(following.command_x, "LEFT")
        self.assertEqual(following.command_y, "HOLD")
        self.assertEqual(holding.state, "NO_TARGET_HOLD")
        self.assertEqual(holding.direction, "HOLD")

    def test_centered_confidence_dropout_holds_without_predictive_motion(self) -> None:
        self.update_box((20, 20, 80, 80))

        missing = self.controller.update(None, 100, 100, now=0.1)

        self.assertEqual(missing.state, "NO_TARGET_HOLD")
        self.assertEqual(missing.direction, "HOLD")


class HeadsControllerTests(unittest.TestCase):
    """Keep every head in frame, then hold on the median of the heads."""

    WIDTH = 640
    HEIGHT = 480

    def controller(self, **overrides: float) -> AutoFrameController:
        settings: dict[str, float | str] = {
            "ema_alpha": 1.0,
            "deadzone_width": 0.12,
            "deadzone_height": 0.12,
            "subject_y_ratio": 0.05,
            "home_after_seconds": 5.0,
            "tracking_mode": "heads",
            "head_ratio": 0.28,
            "head_anchor_ratio": 0.33,
            "head_clearance": 0.06,
            "head_clearance_stop": 0.10,
        }
        settings.update(overrides)
        return AutoFrameController(**settings)  # type: ignore[arg-type]

    def update(
        self,
        controller: AutoFrameController,
        boxes: tuple[tuple[float, float, float, float], ...],
    ) -> CameraCommand:
        objects = tuple(
            tracked(index + 1, box) for index, box in enumerate(boxes)
        )
        decision = make_decision(objects, len(objects))
        return controller.update(decision, self.WIDTH, self.HEIGHT, now=0.0)

    def test_head_touching_the_top_edge_commands_up(self) -> None:
        command = self.update(
            self.controller(),
            ((150, 0, 300, 400), (380, 150, 500, 430)),
        )

        self.assertEqual(command.command_y, "UP")
        self.assertLess(command.error_y, 0.0)
        self.assertTrue(command.heads_fit)

    def test_every_head_clear_of_the_edges_holds(self) -> None:
        command = self.update(
            self.controller(),
            ((150, 120, 300, 430), (380, 130, 500, 440)),
        )

        self.assertEqual(command.command_x, "HOLD")
        self.assertEqual(command.command_y, "HOLD")
        self.assertEqual(command.error_y, 0.0)

    def test_reported_box_and_centre_describe_the_heads(self) -> None:
        controller = self.controller()
        command = self.update(
            controller,
            ((150, 120, 300, 430), (380, 130, 500, 440)),
        )

        # Head slices span 120-206.8 and 130-216.8; medians average to 168.4.
        self.assertAlmostEqual(command.group_box[1], 120 / self.HEIGHT, places=3)
        self.assertAlmostEqual(command.group_box[3], 216.8 / self.HEIGHT, places=3)
        self.assertAlmostEqual(command.center_y, 168.4 / self.HEIGHT, places=3)

    def test_median_drift_inside_the_deadzone_does_not_move(self) -> None:
        # Median sits just above the 0.33 anchor, well inside the 0.12 box.
        command = self.update(
            self.controller(),
            ((150, 120, 300, 300), (380, 130, 500, 310)),
        )

        self.assertEqual(command.command_y, "HOLD")

    def test_median_far_below_the_anchor_tilts_down(self) -> None:
        command = self.update(
            self.controller(),
            ((150, 250, 300, 430), (380, 260, 500, 440)),
        )

        self.assertEqual(command.command_y, "DOWN")
        self.assertGreater(command.error_y, 0.0)

    def test_median_pull_never_eats_the_clearance_it_just_restored(self) -> None:
        # The top head sits exactly on the stop margin while the median is far
        # below the anchor. Chasing the median here is what caused a limit
        # cycle, so the axis must refuse to move.
        top = self.HEIGHT * 0.10
        command = self.update(
            self.controller(),
            ((150, top, 300, 430), (380, 300, 500, 460)),
        )

        self.assertEqual(command.command_y, "HOLD")
        self.assertTrue(command.heads_fit)

    def test_heads_taller_than_the_frame_hold_and_report_the_failure(self) -> None:
        command = self.update(
            self.controller(),
            ((150, 0, 300, 150), (380, 455, 500, 605)),
        )

        self.assertEqual(command.command_y, "HOLD")
        self.assertEqual(command.error_y, 0.0)
        self.assertFalse(command.heads_fit)

    def test_head_beyond_the_left_edge_commands_left(self) -> None:
        command = self.update(
            self.controller(),
            ((0, 150, 120, 430), (300, 160, 420, 440)),
        )

        self.assertEqual(command.command_x, "LEFT")
        self.assertLess(command.error_x, 0.0)

    def test_median_ignores_a_single_outlier_among_three(self) -> None:
        controller = self.controller()
        centred = self.update(
            controller,
            ((100, 150, 200, 430), (300, 155, 400, 435), (500, 160, 600, 440)),
        )
        outlier = self.update(
            self.controller(),
            ((100, 150, 200, 430), (300, 155, 400, 435), (500, 300, 600, 470)),
        )

        # One person dropping low moves the mean but not the median.
        self.assertAlmostEqual(centred.center_y, outlier.center_y, places=3)

    def test_invalid_head_settings_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            self.controller(head_anchor_ratio=0.0)
        with self.assertRaises(ValueError):
            self.controller(head_clearance=0.10, head_clearance_stop=0.06)


if __name__ == "__main__":
    unittest.main()
