from __future__ import annotations

import unittest
from datetime import datetime
from unittest import mock

from fastapi import HTTPException

from video_editor import service
from video_editor.analysis_jobs import AnalysisJob
from video_editor.service import (
    RecommendationRequest,
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

    def test_unknown_capture_is_not_silently_mapped(self) -> None:
        request = RecommendationRequest(
            videoId="unknown",
            capturedAt="2026-08-01T12:00:00",
        )
        with self.assertRaises(KeyError):
            build_fixture_recommendation(request)


class AnalysisFlowTest(unittest.TestCase):
    """fixture가 없는 영상의 분석 요구·상태 응답."""

    def test_recommend_requires_analysis_when_no_fixture_or_cache(self) -> None:
        request = RecommendationRequest(videoId="new-video")
        with (
            mock.patch.object(service, "_load_cached_analyses", return_value=None),
            mock.patch.object(service.jobs, "get", return_value=None),
        ):
            with self.assertRaises(HTTPException) as caught:
                service.recommend(request)
        self.assertEqual(404, caught.exception.status_code)
        self.assertEqual("analysis-required", caught.exception.detail)

    def test_recommend_reports_running_analysis(self) -> None:
        running = AnalysisJob(video_id="new-video")
        request = RecommendationRequest(videoId="new-video")
        with (
            mock.patch.object(service, "_load_cached_analyses", return_value=None),
            mock.patch.object(service.jobs, "get", return_value=running),
        ):
            with self.assertRaises(HTTPException) as caught:
                service.recommend(request)
        self.assertEqual(404, caught.exception.status_code)
        self.assertEqual("analysis-running", caught.exception.detail)

    def test_recommend_uses_cached_analyses(self) -> None:
        # 검증 fixture 05를 "업로드 분석 결과"인 척 캐시로 돌려주면
        # fixture 경로와 같은 레시피가 나와야 한다.
        analyses = {
            kind: service._read_analysis("05_20260727_162525", kind)
            for kind in ("yamnet", "audio", "video", "expression")
        }
        request = RecommendationRequest(videoId="new-video", durationPreset="medium")
        with (
            mock.patch.object(service, "_load_cached_analyses", return_value=analyses),
            mock.patch.object(service.store, "put") as stored,
        ):
            response = service.recommend(request)
        recipe = response["recipe"]
        self.assertEqual("new-video", recipe["videoId"])
        self.assertTrue(recipe["analyzed"])
        self.assertEqual(58_000, recipe["cut"]["startMs"])
        stored.assert_called_once()

    def test_status_is_none_without_job_or_cache(self) -> None:
        with mock.patch.object(service, "_load_cached_analyses", return_value=None):
            status = service.analysis_status("new-video")
        self.assertEqual({"videoId": "new-video", "status": "none", "progress": 0.0}, status)

    def test_status_is_done_with_cache_after_restart(self) -> None:
        with mock.patch.object(service, "_load_cached_analyses", return_value={}):
            # 빈 dict라도 None이 아니면 캐시가 있는 것으로 본다(4종 확인은
            # _load_cached_analyses 몫이고, 여기서는 대체돼 있다).
            status = service.analysis_status("new-video")
        self.assertEqual("done", status["status"])


if __name__ == "__main__":
    unittest.main()
