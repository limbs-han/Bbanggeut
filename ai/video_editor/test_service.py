from __future__ import annotations

import unittest
from datetime import datetime

from ai.video_editor.service import RecommendationRequest, _fixture_stem, build_fixture_recommendation


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

    def test_unknown_capture_is_not_silently_mapped(self) -> None:
        request = RecommendationRequest(
            videoId="unknown",
            capturedAt="2026-08-01T12:00:00",
        )
        with self.assertRaises(KeyError):
            build_fixture_recommendation(request)


if __name__ == "__main__":
    unittest.main()
