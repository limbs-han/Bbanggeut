from __future__ import annotations

import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

import jwt
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


_TEST_SECRET = "unit-test-signing-key-0123456789abcdef"


def _token(*, issuer: str = "wj-server", expired: bool = False) -> str:
    now = datetime.now(timezone.utc)
    exp = now - timedelta(minutes=5) if expired else now + timedelta(minutes=15)
    return jwt.encode(
        {"iss": issuer, "sub": "user-1", "sid": "session-1", "exp": exp},
        _TEST_SECRET,
        algorithm="HS256",
    )


class AuthTest(unittest.TestCase):
    def test_auth_disabled_without_secret(self) -> None:
        with mock.patch.object(service, "EDITOR_JWT_SECRET", None):
            self.assertIsNone(service.verify_bearer(None))

    def test_missing_and_malformed_headers_are_rejected(self) -> None:
        with mock.patch.object(service, "EDITOR_JWT_SECRET", _TEST_SECRET):
            self.assertIsNotNone(service.verify_bearer(None))
            self.assertIsNotNone(service.verify_bearer("Basic abc"))
            self.assertIsNotNone(service.verify_bearer("Bearer not-a-jwt"))

    def test_valid_backend_access_token_passes(self) -> None:
        with mock.patch.object(service, "EDITOR_JWT_SECRET", _TEST_SECRET):
            self.assertIsNone(service.verify_bearer(f"Bearer {_token()}"))

    def test_live_token_issuer_is_rejected(self) -> None:
        # 라이브 토큰은 같은 키로 서명되지만 iss가 다르다 — 편집 API 재사용 금지.
        with mock.patch.object(service, "EDITOR_JWT_SECRET", _TEST_SECRET):
            self.assertIsNotNone(
                service.verify_bearer(f"Bearer {_token(issuer='wj-live')}")
            )

    def test_expired_token_is_rejected(self) -> None:
        with mock.patch.object(service, "EDITOR_JWT_SECRET", _TEST_SECRET):
            self.assertIsNotNone(
                service.verify_bearer(f"Bearer {_token(expired=True)}")
            )


class SourceUrlTest(unittest.TestCase):
    def test_allows_backend_presigned_host_only(self) -> None:
        self.assertTrue(
            service.source_url_allowed(
                "https://i15e201.p.ssafy.io/william-james-videos/a.mp4?X-Amz=1"
            )
        )
        # SSRF 차단: 내부 주소·다른 호스트·http는 서버가 대신 받지 않는다.
        self.assertFalse(service.source_url_allowed("http://minio:9000/a.mp4"))
        self.assertFalse(service.source_url_allowed("https://minio:9000/a.mp4"))
        self.assertFalse(service.source_url_allowed("https://127.0.0.1/a.mp4"))
        self.assertFalse(service.source_url_allowed("https://evil.example/a.mp4"))
        self.assertFalse(service.source_url_allowed(""))


if __name__ == "__main__":
    unittest.main()
