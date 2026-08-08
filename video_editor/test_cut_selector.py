from __future__ import annotations

import unittest
from types import SimpleNamespace
from typing import Any

from video_editor.adaptive_selector import (
    AdaptiveConfig,
    build_timeline,
    select_adaptive_highlight,
)
from video_editor.adaptive_cli import build_adaptive_recipe
from video_editor.cli import build_recipe
from video_editor.cut_selector import select_cut
from video_editor.models import ScoreSegment, SelectorConfig
from video_editor.audio_features import extract_audio_features
from video_editor.yamnet_analysis import (
    is_laughter_category,
    is_music_category,
    is_speech_category,
)
from video_editor.video_features import normalize_video_windows
from video_editor.duration_presets import apply_duration_preset
from video_editor.face_tracks import build_face_tracks
from video_editor.zoom_planner import plan_zoom_segments
from video_editor.render_video import build_zoompan_filter
from video_editor.expression_analysis import _face_reaction


def segment(
    start_s: int,
    end_s: int,
    score: float,
    *,
    start_boundary: float = 0.8,
    end_boundary: float = 0.8,
) -> ScoreSegment:
    return ScoreSegment(
        start_ms=start_s * 1000,
        end_ms=end_s * 1000,
        edit_score=score,
        start_boundary_score=start_boundary,
        end_boundary_score=end_boundary,
    )


class CutSelectorTests(unittest.TestCase):
    def test_selects_high_quality_window_while_preserving_anchor_context(self) -> None:
        segments = [
            segment(0, 20, 0.1),
            segment(20, 40, 0.3),
            segment(40, 55, 0.9),
            segment(55, 70, 1.0),
            segment(70, 85, 0.8),
            segment(85, 105, 0.2),
            segment(105, 120, 0.1),
        ]

        result = select_cut(
            duration_ms=120_000,
            anchor_start_ms=59_000,
            anchor_end_ms=62_000,
            segments=segments,
        )

        self.assertLessEqual(result.start_ms, 49_000)
        self.assertGreaterEqual(result.end_ms, 72_000)
        self.assertGreaterEqual(result.duration_ms, 45_000)
        self.assertLessEqual(result.duration_ms, 65_000)
        self.assertFalse(result.used_fallback)

    def test_mean_quality_and_length_penalty_do_not_always_select_65_seconds(self) -> None:
        config = SelectorConfig(context_before_ms=0, context_after_ms=0)
        segments = [
            segment(0, 15, 0.1),
            segment(15, 30, 0.2),
            segment(30, 45, 1.0),
            segment(45, 60, 1.0),
            segment(60, 75, 1.0),
            segment(75, 90, 0.05),
            segment(90, 105, 0.05),
            segment(105, 120, 0.05),
        ]

        result = select_cut(
            duration_ms=120_000,
            anchor_start_ms=58_000,
            anchor_end_ms=62_000,
            segments=segments,
            config=config,
        )

        self.assertEqual(45_000, result.duration_ms)
        self.assertEqual((30_000, 75_000), (result.start_ms, result.end_ms))

    def test_prefers_safer_boundaries_when_content_scores_tie(self) -> None:
        config = SelectorConfig(context_before_ms=0, context_after_ms=0)
        segments = [
            segment(0, 15, 0.5),
            segment(15, 30, 0.5, start_boundary=0.1),
            segment(30, 45, 0.5, start_boundary=1.0),
            segment(45, 60, 0.5),
            segment(60, 75, 0.5, end_boundary=1.0),
            segment(75, 90, 0.5, end_boundary=0.1),
            segment(90, 105, 0.5),
        ]

        result = select_cut(
            duration_ms=105_000,
            anchor_start_ms=50_000,
            anchor_end_ms=55_000,
            segments=segments,
            config=config,
        )

        self.assertEqual((30_000, 75_000), (result.start_ms, result.end_ms))

    def test_falls_back_to_centered_minimum_window_without_boundaries(self) -> None:
        result = select_cut(
            duration_ms=120_000,
            anchor_start_ms=59_000,
            anchor_end_ms=61_000,
            segments=[],
        )

        self.assertEqual((37_500, 82_500), (result.start_ms, result.end_ms))
        self.assertTrue(result.used_fallback)
        self.assertEqual(0, result.candidate_count)

    def test_short_source_is_returned_whole(self) -> None:
        result = select_cut(
            duration_ms=30_000,
            anchor_start_ms=10_000,
            anchor_end_ms=12_000,
            segments=[segment(0, 30, 0.8)],
        )

        self.assertEqual((0, 30_000), (result.start_ms, result.end_ms))
        self.assertTrue(result.used_fallback)

    def test_anchor_near_edge_relaxes_unavailable_context(self) -> None:
        segments = [
            segment(0, 15, 0.8),
            segment(15, 30, 0.8),
            segment(30, 45, 0.7),
            segment(45, 60, 0.2),
            segment(60, 75, 0.1),
        ]

        result = select_cut(
            duration_ms=75_000,
            anchor_start_ms=2_000,
            anchor_end_ms=5_000,
            segments=segments,
        )

        self.assertEqual(0, result.start_ms)
        self.assertGreaterEqual(result.end_ms, 45_000)
        self.assertFalse(result.used_fallback)

    def test_cli_builds_versioned_recipe(self) -> None:
        recipe = build_recipe(
            {
                "sourceVideoId": "video-1",
                "analysisVersion": "analysis-v1",
                "durationMs": 60_000,
                "anchorMs": 30_000,
                "segments": [
                    {
                        "startMs": 0,
                        "endMs": 60_000,
                        "editScore": 0.7,
                        "startBoundaryScore": 1.0,
                        "endBoundaryScore": 1.0,
                    }
                ],
            }
        )

        self.assertEqual("v1", recipe["recipeVersion"])
        self.assertEqual("video-1", recipe["sourceVideoId"])
        self.assertEqual(1, recipe["revision"])
        self.assertGreaterEqual(recipe["cut"]["durationMs"], 45_000)

    def test_cli_accepts_anchor_interval_without_anchor_point(self) -> None:
        recipe = build_recipe(
            {
                "durationMs": 60_000,
                "anchorStartMs": 28_000,
                "anchorEndMs": 32_000,
                "segments": [],
            }
        )

        self.assertLessEqual(recipe["cut"]["startMs"], 28_000)
        self.assertGreaterEqual(recipe["cut"]["endMs"], 32_000)

    def test_rejects_segment_outside_video(self) -> None:
        with self.assertRaisesRegex(ValueError, "exceeds video duration"):
            select_cut(
                duration_ms=60_000,
                anchor_start_ms=20_000,
                anchor_end_ms=25_000,
                segments=[segment(0, 75, 0.5)],
            )

    def test_rejects_overlapping_score_segments(self) -> None:
        with self.assertRaisesRegex(ValueError, "must not overlap"):
            select_cut(
                duration_ms=60_000,
                anchor_start_ms=20_000,
                anchor_end_ms=25_000,
                segments=[segment(0, 30, 0.5), segment(20, 60, 0.7)],
            )

    def test_recognizes_yamnet_laughter_family(self) -> None:
        self.assertTrue(is_laughter_category("Chuckle, chortle"))
        self.assertTrue(is_laughter_category("Baby laughter"))
        self.assertFalse(is_laughter_category("Speech"))
        self.assertTrue(is_speech_category("Child speech, kid speaking"))
        self.assertTrue(is_speech_category("Conversation"))
        self.assertTrue(is_music_category("Pop music"))

    def test_audio_features_detect_loudness_rise(self) -> None:
        import numpy as np

        quiet = np.full(8_000, 0.01, dtype=np.float32)
        loud = np.full(8_000, 0.2, dtype=np.float32)
        rows = extract_audio_features(np.concatenate((quiet, loud)))

        self.assertEqual(2, len(rows))
        self.assertLess(rows[0]["dbfs"], rows[1]["dbfs"])
        self.assertGreater(rows[1]["loudnessRise"], 0.9)

    def test_adaptive_selector_keeps_short_isolated_event_short(self) -> None:
        timeline = []
        for second in range(120):
            active = 50 <= second < 68
            timeline.append(
                {
                    "startMs": second * 1000,
                    "endMs": (second + 1) * 1000,
                    "eventScore": 0.8 if active else 0.01,
                    "continuityScore": 0.7 if active else 0.01,
                    "socialEvent": 0.8 if active else 0.01,
                    "ambientEvent": 0.0,
                    "dialogueEvent": 0.0,
                }
            )
        selection = select_adaptive_highlight(
            timeline,
            {"durationMs": 120_000, "yamnetWindows": []},
        )

        self.assertLess(selection["durationMs"], 30_000)
        self.assertLessEqual(selection["startMs"], 51_000)
        self.assertGreaterEqual(selection["endMs"], 68_000)

    def test_music_event_includes_preceding_motion_and_later_resolution(self) -> None:
        timeline = []
        for second in range(120):
            moving = 60 <= second < 96 or 102 <= second < 118
            music = 102 <= second < 114
            event = 0.8 if music else 0.02
            timeline.append(
                {
                    "startMs": second * 1000,
                    "endMs": (second + 1) * 1000,
                    "eventScore": event,
                    "continuityScore": 0.8 if music else 0.01,
                    "socialEvent": 0.0,
                    "ambientEvent": event,
                    "dialogueEvent": 0.0,
                    "visualEvent": 0.5 if moving else 0.0,
                    "features": {
                        "music": 0.8 if music else 0.0,
                        "motion": 0.8 if moving else 0.1,
                    },
                }
            )

        selection = select_adaptive_highlight(
            timeline,
            {"durationMs": 120_000, "yamnetWindows": []},
        )

        self.assertLessEqual(selection["startMs"], 60_000)
        self.assertEqual(120_000, selection["endMs"])
        self.assertEqual("ambient-motion-episode", selection["flowExpansion"])

    def test_timeline_scores_late_music_event(self) -> None:
        timeline = build_timeline(
            {
                "durationMs": 120_000,
                "yamnetWindows": [
                    {
                        "startMs": 102_000,
                        "endMs": 103_000,
                        "musicScore": 0.9,
                        "topCategories": [{"name": "Music", "score": 0.9}],
                    }
                ],
            },
            {
                "durationMs": 120_000,
                "audioWindows": [
                    {
                        "startMs": 102_000,
                        "endMs": 103_000,
                        "relativeLoudness": 1.0,
                        "loudnessRise": 1.0,
                        "normalizedFlux": 0.5,
                    }
                ],
            },
        )
        selection = select_adaptive_highlight(
            timeline,
            {"durationMs": 120_000, "yamnetWindows": []},
            config=AdaptiveConfig(minimum_duration_ms=8_000),
        )

        self.assertGreaterEqual(selection["seedStartMs"], 101_000)

    def test_adaptive_recipe_keeps_analysis_versions(self) -> None:
        recipe = build_adaptive_recipe(
            {
                "analysisVersion": "yamnet-v1",
                "sourcePath": "sample.mp4",
                "durationMs": 20_000,
                "yamnetWindows": [],
            },
            {
                "analysisVersion": "audio-v1",
                "durationMs": 20_000,
                "audioWindows": [],
            },
        )

        self.assertEqual("v2", recipe["recipeVersion"])
        self.assertNotIn("stt", recipe["analysisVersions"])
        self.assertEqual("sample.mp4", recipe["sourcePath"])

    def test_video_features_ignore_startup_change_and_detect_later_cut(self) -> None:
        rows = []
        for index, change in enumerate([0.0, 0.02, 0.02, 0.02, 0.02, 0.20]):
            rows.append(
                {
                    "startMs": index * 500,
                    "endMs": (index + 1) * 500,
                    "brightness": 0.5,
                    "contrastRaw": 0.2,
                    "sharpnessRaw": 100.0,
                    "motionRaw": change,
                    "contentChangeRaw": change,
                    "faceCount": 1,
                    "facePresence": 1.0,
                    "largestFaceArea": 0.08,
                    "faceCenterScore": 1.0,
                    "faceProminence": 1.0,
                }
            )

        normalized = normalize_video_windows(rows)

        self.assertEqual(0.0, normalized[1]["sceneCutScore"])
        self.assertGreater(normalized[-1]["sceneCutScore"], 0.5)
        self.assertEqual(1.0, normalized[-1]["motionScore"])

    def test_visual_signal_supports_but_does_not_replace_strong_audio_event(self) -> None:
        yamnet = {
            "durationMs": 40_000,
            "yamnetWindows": [
                {
                    "startMs": 10_000,
                    "endMs": 11_000,
                    "laughterScore": 0.35,
                    "speechScore": 0.5,
                }
            ],
        }
        audio = {"durationMs": 40_000, "audioWindows": []}
        video = {
            "durationMs": 40_000,
            "videoWindows": [
                {
                    "startMs": 30_000,
                    "endMs": 31_000,
                    "motionScore": 1.0,
                    "contentChange": 1.0,
                    "sceneCutScore": 1.0,
                    "facePresence": 1.0,
                    "faceProminence": 1.0,
                    "faceChange": 1.0,
                    "visualQuality": 1.0,
                }
            ],
        }

        timeline = build_timeline(yamnet, audio, video)

        self.assertGreater(timeline[10]["eventScore"], timeline[30]["eventScore"])
        self.assertGreater(timeline[30]["visualEvent"], 0.9)

    def test_video_analysis_upgrades_recipe_version(self) -> None:
        base = {
            "analysisVersion": "base-v1",
            "sourcePath": "sample.mp4",
            "durationMs": 20_000,
        }
        recipe = build_adaptive_recipe(
            {**base, "yamnetWindows": []},
            {**base, "audioWindows": []},
            {**base, "analysisVersion": "video-v1", "videoWindows": []},
        )

        self.assertEqual("v3", recipe["recipeVersion"])
        self.assertEqual("video-v1", recipe["analysisVersions"]["video"])

    def test_medium_preset_constrains_a_long_story_around_the_seed(self) -> None:
        timeline = [
            {
                "startMs": second * 1000,
                "endMs": (second + 1) * 1000,
                "eventScore": 0.8 if 50 <= second < 60 else 0.2,
                "continuityScore": 0.5,
            }
            for second in range(120)
        ]
        selection = {
            "startMs": 0,
            "endMs": 120_000,
            "durationMs": 120_000,
            "seedStartMs": 54_000,
            "seedEndMs": 55_000,
        }

        result = apply_duration_preset(
            selection,
            timeline,
            {"durationMs": 120_000, "yamnetWindows": []},
            None,
            "medium",
        )

        self.assertGreaterEqual(result["durationMs"], 35_000)
        self.assertLessEqual(result["durationMs"], 65_000)
        self.assertLessEqual(result["startMs"], 54_000)
        self.assertGreaterEqual(result["endMs"], 55_000)

    def test_zoom_toggle_and_face_focus_generate_sparse_segments(self) -> None:
        timeline = [
            {
                "startMs": second * 1000,
                "endMs": (second + 1) * 1000,
                "socialEvent": 0.8 if 19 <= second <= 21 else 0.1,
                "ambientEvent": 0.0,
                "features": {
                    "laughter": 0.8 if 19 <= second <= 21 else 0.0,
                    "reaction": 0.0,
                    "loudnessRise": 0.5 if 19 <= second <= 21 else 0.0,
                },
            }
            for second in range(40)
        ]
        expression = {
            "expressionWindows": [
                {
                    "startMs": sample * 250,
                    "endMs": (sample + 1) * 250,
                    "faceCount": 1,
                    "reactionScore": 0.9 if 79 <= sample <= 81 else 0.1,
                    "focusX": 0.3,
                    "focusY": 0.4,
                    "faceWidth": 0.15,
                    "faceHeight": 0.15,
                    "dominantExpression": "smile",
                }
                for sample in range(160)
            ]
        }
        cut = {"startMs": 0, "endMs": 40_000, "durationMs": 40_000}

        self.assertEqual(
            [], plan_zoom_segments(timeline, expression, cut, enabled=False)
        )
        zooms = plan_zoom_segments(timeline, expression, cut, enabled=True)

        self.assertEqual(1, len(zooms))
        self.assertAlmostEqual(0.3, zooms[0]["focusX"])
        self.assertAlmostEqual(0.4, zooms[0]["focusY"])
        self.assertAlmostEqual(2.222222, zooms[0]["scale"], places=5)
        self.assertAlmostEqual(1.0 / 3.0, zooms[0]["targetFaceHeight"], places=5)
        self.assertEqual(0, zooms[0]["rampMs"])
        self.assertGreaterEqual(zooms[0]["endMs"] - zooms[0]["startMs"], 1_200)
        self.assertLessEqual(zooms[0]["startMs"], 20_000)
        self.assertGreaterEqual(zooms[0]["endMs"], 20_000)
        self.assertGreater(zooms[0]["soundScore"], 0.5)
        filter_text = build_zoompan_filter(1280, 720, 30.0, 0, zooms)
        self.assertIn("between(on", filter_text)
        self.assertNotIn("in_time", filter_text)
        self.assertNotIn("min(min", filter_text)

    def test_zoom_follows_the_face_it_locked_on(self) -> None:
        """확대해 둔 채로 사람이 움직이면 초점도 그 사람을 따라간다."""
        timeline = [
            {
                "startMs": second * 1000,
                "endMs": (second + 1) * 1000,
                "socialEvent": 0.8 if 19 <= second <= 21 else 0.1,
                "ambientEvent": 0.0,
                "features": {
                    "laughter": 0.8 if 19 <= second <= 21 else 0.0,
                    "reaction": 0.0,
                    "loudnessRise": 0.5 if 19 <= second <= 21 else 0.0,
                },
            }
            for second in range(40)
        ]
        # 웃는 사람은 웃음이 터진 20초 언저리에 왼쪽(0.30)에서 오른쪽으로
        # 걸어간다. 반대편(0.85)에는 자리를 지키는 다른 사람이 있다.
        def walker_x(sample: int) -> float:
            return round(0.30 + 0.01 * min(24, max(0, sample - 72)), 4)

        expression = {
            "expressionWindows": [
                {
                    "startMs": sample * 250,
                    "endMs": (sample + 1) * 250,
                    "faceCount": 2,
                    "reactionScore": 0.9 if 79 <= sample <= 81 else 0.1,
                    "focusX": walker_x(sample),
                    "focusY": 0.4,
                    "faceWidth": 0.15,
                    "faceHeight": 0.15,
                    "dominantExpression": "smile",
                    "faces": [
                        {
                            "focusX": walker_x(sample),
                            "focusY": 0.4,
                            "faceHeight": 0.15,
                        },
                        {"focusX": 0.85, "focusY": 0.6, "faceHeight": 0.15},
                    ],
                }
                for sample in range(160)
            ]
        }
        cut = {"startMs": 0, "endMs": 40_000, "durationMs": 40_000}
        face_tracks = build_face_tracks(expression)

        zooms = plan_zoom_segments(
            timeline, expression, cut, enabled=True, face_tracks=face_tracks
        )

        self.assertEqual(1, len(zooms))
        zoom = zooms[0]
        walker = next(
            track
            for track in face_tracks
            if abs(track["samples"][0]["x"] - 0.30) < 0.02
        )
        # 걸어가는 사람의 궤적을 잡았다 — 자리를 지키는 옆 사람이 아니다.
        self.assertEqual(walker["id"], zoom["faceTrackId"])
        track = zoom["focusTrack"]
        self.assertGreaterEqual(len(track), 2)
        self.assertEqual(zoom["startMs"], track[0]["ms"])
        self.assertEqual(zoom["endMs"], track[-1]["ms"])
        # 초점은 사람이 간 방향(오른쪽)으로, 간 만큼을 죽은 구간만큼 뒤에서
        # 따라간다 — 앞질러 가지는 않는다.
        moved = track[-1]["dx"] - track[0]["dx"]
        walked = walker_x(zoom["endMs"] // 250) - walker_x(zoom["startMs"] // 250)
        self.assertGreater(moved, walked / 2)
        self.assertLessEqual(moved, walked)
        # 위아래로는 움직이지 않았으니 초점도 가만히 있는다.
        self.assertLess(max(abs(point["dy"]) for point in track), 0.01)
        # 정지 초점은 그대로다 — 옛 앱은 이 값만 읽는다.
        self.assertAlmostEqual(walker_x(80), zoom["focusX"], places=2)

        # 렌더러는 키프레임마다 초점이 바뀌는 표현식을 만든다.
        filter_text = build_zoompan_filter(1280, 720, 30.0, 0, zooms)
        self.assertIn("gte(on", filter_text)

    def test_zoom_caps_scale_so_the_face_stays_in_frame(self) -> None:
        """가장자리에 선 얼굴은 상한이 낮다 — 조금만 키워도 잘리기 때문이다."""
        timeline = [
            {
                "startMs": second * 1000,
                "endMs": (second + 1) * 1000,
                "socialEvent": 0.8 if 19 <= second <= 21 else 0.1,
                "ambientEvent": 0.0,
                "features": {
                    "laughter": 0.8 if 19 <= second <= 21 else 0.0,
                    "reaction": 0.0,
                    "loudnessRise": 0.5 if 19 <= second <= 21 else 0.0,
                },
            }
            for second in range(40)
        ]

        def plan(face_x: float) -> dict[str, Any]:
            expression = {
                "expressionWindows": [
                    {
                        "startMs": sample * 250,
                        "endMs": (sample + 1) * 250,
                        "faceCount": 1,
                        "reactionScore": 0.9 if 79 <= sample <= 81 else 0.1,
                        "focusX": face_x,
                        "focusY": 0.5,
                        "faceWidth": 0.12,
                        "faceHeight": 0.15,
                        "dominantExpression": "smile",
                        "faces": [
                            {
                                "focusX": face_x,
                                "focusY": 0.5,
                                "faceWidth": 0.12,
                                "faceHeight": 0.15,
                            }
                        ],
                    }
                    for sample in range(160)
                ]
            }
            zooms = plan_zoom_segments(
                timeline,
                expression,
                {"startMs": 0, "endMs": 40_000, "durationMs": 40_000},
                enabled=True,
                face_tracks=build_face_tracks(expression),
            )
            return zooms[0]

        centered = plan(0.50)
        edge = plan(0.14)

        # 한가운데 선 얼굴은 상한까지 열려 있다.
        self.assertEqual(2.80, centered["maxScale"])
        # 왼쪽 끝에 선 얼굴은 훨씬 낮은 값에서 막힌다. 초점 0.14에서 왼쪽
        # 여백 0.02를 남기려면 얼굴 왼쪽 변(0.08)까지 0.06을 0.12로 늘리는
        # 2.0배가 한계다.
        self.assertLess(edge["maxScale"], centered["maxScale"])
        self.assertAlmostEqual(2.0, edge["maxScale"], places=6)
        # 그 상한으로 확대해도 얼굴 상자는 화면 안에 남는다.
        left_edge = 0.14 - 0.12 / 2
        focus = edge["focusX"]
        self.assertGreaterEqual(
            focus + (left_edge - focus) * edge["maxScale"], 0.0
        )

    def test_zoom_without_face_tracks_keeps_a_still_focus(self) -> None:
        """궤적을 못 찾으면 예전처럼 초점이 고정이다."""
        timeline = [
            {
                "startMs": second * 1000,
                "endMs": (second + 1) * 1000,
                "socialEvent": 0.8 if 19 <= second <= 21 else 0.1,
                "ambientEvent": 0.0,
                "features": {
                    "laughter": 0.8 if 19 <= second <= 21 else 0.0,
                    "reaction": 0.0,
                    "loudnessRise": 0.5 if 19 <= second <= 21 else 0.0,
                },
            }
            for second in range(40)
        ]
        expression = {
            "expressionWindows": [
                {
                    "startMs": sample * 250,
                    "endMs": (sample + 1) * 250,
                    "faceCount": 1,
                    "reactionScore": 0.9 if 79 <= sample <= 81 else 0.1,
                    "focusX": 0.3,
                    "focusY": 0.4,
                    "faceWidth": 0.15,
                    "faceHeight": 0.15,
                    "dominantExpression": "smile",
                }
                for sample in range(160)
            ]
        }
        cut = {"startMs": 0, "endMs": 40_000, "durationMs": 40_000}

        zooms = plan_zoom_segments(timeline, expression, cut, enabled=True)

        self.assertEqual([], zooms[0]["focusTrack"])
        self.assertIsNone(zooms[0]["faceTrackId"])
        self.assertNotIn("gte(on", build_zoompan_filter(1280, 720, 30.0, 0, zooms))

    def test_surprise_blendshapes_are_calibrated_against_smiles(self) -> None:
        categories = [
            SimpleNamespace(category_name="jawOpen", score=0.35),
            SimpleNamespace(category_name="eyeWideLeft", score=0.40),
            SimpleNamespace(category_name="eyeWideRight", score=0.40),
            SimpleNamespace(category_name="browInnerUp", score=0.30),
            SimpleNamespace(category_name="mouthSmileLeft", score=0.05),
            SimpleNamespace(category_name="mouthSmileRight", score=0.05),
        ]
        landmarks = [
            SimpleNamespace(x=0.4, y=0.3),
            SimpleNamespace(x=0.6, y=0.7),
        ]

        reaction = _face_reaction(categories, landmarks)

        self.assertEqual("surprise", reaction["dominantExpression"])
        self.assertGreater(reaction["surpriseScore"], 0.5)
        self.assertGreater(
            reaction["surpriseScore"], reaction["surpriseRawScore"]
        )

    def test_preset_and_zoom_upgrade_recipe_to_v4(self) -> None:
        base = {
            "analysisVersion": "base-v1",
            "sourcePath": "sample.mp4",
            "durationMs": 40_000,
        }
        video = {
            **base,
            "analysisVersion": "video-v1",
            "videoWindows": [],
        }
        expression = {
            **base,
            "analysisVersion": "expression-v1",
            "expressionWindows": [],
        }

        recipe = build_adaptive_recipe(
            {**base, "yamnetWindows": []},
            {**base, "audioWindows": []},
            video,
            expression,
            duration_preset="short",
            zoom_enabled=True,
        )

        self.assertEqual("v10", recipe["recipeVersion"])
        self.assertEqual("short", recipe["durationPreset"])
        self.assertTrue(recipe["zoomEnabled"])


if __name__ == "__main__":
    unittest.main()
