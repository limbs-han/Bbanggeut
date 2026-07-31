"""Unit tests for the hardware-independent auto-framing decisions."""

from __future__ import annotations

import unittest

from yolov8_autoframe_jetson import (
    AutoFrameController,
    TrackedObject,
    choose_best_group,
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


if __name__ == "__main__":
    unittest.main()
