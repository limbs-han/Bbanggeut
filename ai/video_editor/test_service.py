from __future__ import annotations

import unittest
from datetime import datetime

from ai.video_editor.service import (
    RecommendationRequest,
    _face_tracks,
    _fixture_stem,
    build_fixture_recommendation,
)


class VideoEditorServiceTest(unittest.TestCase):
    def test_matches_fixture_by_local_capture_minute(self) -> None:
        self.assertEqual(
            "05_20260727_162525",
            _fixture_stem(datetime.fromisoformat("2026-07-27T16:25:30")),
        )

    def test_builds_cut_and_zoom_recipe(self) -> None:
        recipe = build_fixture_recommendation(
            RecommendationRequest(
                videoId="video-5",
                capturedAt="2026-07-27T16:25:30",
                zoomEnabled=True,
            )
        )
        self.assertEqual(58_000, recipe["cut"]["startMs"])
        self.assertEqual(120_000, recipe["cut"]["endMs"])
        self.assertEqual("medium", recipe["durationPreset"])
        self.assertTrue(recipe["zoomEnabled"])
        self.assertEqual(1, len(recipe["zoomSegments"]))

    def test_face_tracks_split_people_and_merge_reappearance(self) -> None:
        def window(start: int, faces: list[tuple[float, float]]) -> dict:
            return {
                "startMs": start,
                "endMs": start + 250,
                "faceCount": len(faces),
                "faces": [
                    {"focusX": x, "focusY": y, "faceHeight": 0.3}
                    for x, y in faces
                ],
            }

        # 두 사람(왼쪽 0.2, 오른쪽 0.8)이 1.5초 동안 같이 잡히고,
        # 왼쪽 사람은 잠깐 사라졌다가(2.5~4초) 같은 자리에서 다시 잡힌다.
        windows = [
            *(window(ms, [(0.2, 0.3), (0.8, 0.7)]) for ms in range(0, 1500, 250)),
            *(window(ms, [(0.8, 0.7)]) for ms in range(1500, 4000, 250)),
            *(window(ms, [(0.21, 0.3), (0.8, 0.7)]) for ms in range(4000, 5500, 250)),
        ]
        tracks = _face_tracks({"expressionWindows": windows})

        self.assertEqual(2, len(tracks))
        # 가장 오래 잡힌 사람(오른쪽)이 첫 궤적이다.
        self.assertEqual(22, len(tracks[0]["samples"]))
        self.assertAlmostEqual(0.8, tracks[0]["samples"][0]["x"])
        # 왼쪽 사람은 사라졌다 돌아온 구간이 한 궤적으로 합쳐진다.
        self.assertEqual(12, len(tracks[1]["samples"]))
        self.assertAlmostEqual(0.2, tracks[1]["samples"][0]["x"])
        self.assertAlmostEqual(0.21, tracks[1]["samples"][-1]["x"])

    def test_recipe_carries_face_tracks(self) -> None:
        recipe = build_fixture_recommendation(
            RecommendationRequest(
                videoId="video-5",
                capturedAt="2026-07-27T16:25:30",
                zoomEnabled=True,
            )
        )
        self.assertIn("faceTracks", recipe)
        # 옛 앱 호환: faceTrack은 가장 오래 잡힌 사람의 궤적이다.
        if recipe["faceTracks"]:
            self.assertEqual(
                recipe["faceTracks"][0]["samples"], recipe["faceTrack"]
            )

    def test_unknown_capture_is_not_silently_mapped(self) -> None:
        request = RecommendationRequest(
            videoId="unknown",
            capturedAt="2026-08-01T12:00:00",
        )
        with self.assertRaises(KeyError):
            build_fixture_recommendation(request)


if __name__ == "__main__":
    unittest.main()
