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


class ComicFrameTimelineTest(unittest.TestCase):
    """만화가 편집 분석을 재사용하는 자리.

    같은 영상을 두 번 분석하지 않는다. 편집(자동 컷·줌)이 남긴 결과를 그대로 읽어
    "무슨 일이 일어난 순간"에서 만화 프레임을 뽑는다.
    """

    def test_uses_the_analysis_the_editor_already_stored(self) -> None:
        analyses = {
            kind: service._read_analysis("05_20260727_162525", kind)
            for kind in ("yamnet", "audio", "video", "expression")
        }
        with mock.patch.object(
            service, "_load_cached_analyses", return_value=analyses
        ):
            timeline = service._comic_frame_timeline("video-5")

        self.assertIsNotNone(timeline)
        self.assertTrue(timeline)
        self.assertIn("eventScore", timeline[0])

    def test_falls_back_when_the_video_was_never_analyzed(self) -> None:
        """분석을 안 돌린 영상이라고 만화를 못 만들 이유는 없다 — 등분으로 간다."""
        with mock.patch.object(service, "_load_cached_analyses", return_value=None):
            self.assertIsNone(service._comic_frame_timeline("new-video"))

    def test_a_malformed_analysis_does_not_block_the_comic(self) -> None:
        with mock.patch.object(
            service, "_load_cached_analyses", return_value={"yamnet": {}, "audio": {}}
        ):
            self.assertIsNone(service._comic_frame_timeline("old-video"))


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


class VaultScopeTest(unittest.TestCase):
    """금고(가족) 범위 검사 — 백엔드 판정을 editor-api가 그대로 따른다."""

    def test_disabled_without_backend_url(self) -> None:
        from video_editor import backend_access

        with mock.patch.object(backend_access, "BACKEND_URL", None):
            self.assertTrue(backend_access.can_access_video(None, "v1"))

    def test_denies_without_token_when_enabled(self) -> None:
        from video_editor import backend_access

        with mock.patch.object(
            backend_access, "BACKEND_URL", "https://backend.example"
        ):
            self.assertFalse(backend_access.can_access_video(None, "v1"))

    def test_backend_verdict_is_cached(self) -> None:
        from video_editor import backend_access

        response = mock.MagicMock()
        response.status = 200
        response.__enter__ = mock.Mock(return_value=response)
        response.__exit__ = mock.Mock(return_value=False)
        with (
            mock.patch.object(
                backend_access, "BACKEND_URL", "https://backend.example"
            ),
            mock.patch.object(backend_access, "_cache", {}),
            mock.patch.object(
                backend_access.urllib.request, "urlopen", return_value=response
            ) as opened,
        ):
            self.assertTrue(backend_access.can_access_video("Bearer t", "v1"))
            self.assertTrue(backend_access.can_access_video("Bearer t", "v1"))
        opened.assert_called_once()

    def test_endpoint_returns_403_when_backend_denies(self) -> None:
        request = RecommendationRequest(videoId="other-family-video")
        with mock.patch.object(
            service.backend_access, "can_access_video", return_value=False
        ):
            with self.assertRaises(HTTPException) as caught:
                service.recommend(request, http_request=None)
        self.assertEqual(403, caught.exception.status_code)


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


class TranscriptStoreTest(unittest.TestCase):
    """전사문 보관. 폰마다 다시 돌리던 것을 영상에 한 번만 붙여 둔다."""

    def test_saves_lines_and_reads_them_back(self) -> None:
        request = service.TranscriptSaveRequest(
            lines=[{"startMs": 0, "endMs": 1200, "text": "그거 만지지 마"}]
        )
        with mock.patch.object(service.store, "put") as stored:
            saved = service.save_transcript("v1", request)
        self.assertEqual(1, saved["lines"])
        key, payload = stored.call_args.args
        self.assertEqual("transcripts/v1.json", key)
        self.assertEqual("그거 만지지 마", payload["lines"][0]["text"])

    def test_empty_transcript_is_refused(self) -> None:
        # 빈 것을 저장하면 다음에 "캐시 적중(내용 없음)"으로 읽혀 재시도가
        # 영구히 막힌다. 앱 로컬 캐시에서 겪은 함정이라 여기서도 막는다.
        for lines in ([], [{"startMs": 0, "endMs": 1, "text": "   "}]):
            with self.subTest(lines=lines):
                request = service.TranscriptSaveRequest(lines=lines)
                with mock.patch.object(service.store, "put") as stored:
                    with self.assertRaises(HTTPException) as caught:
                        service.save_transcript("v1", request)
                self.assertEqual(422, caught.exception.status_code)
                stored.assert_not_called()

    def test_missing_transcript_is_404(self) -> None:
        with mock.patch.object(service.store, "get_json", return_value=None):
            with self.assertRaises(HTTPException) as caught:
                service.load_transcript("v1")
        self.assertEqual(404, caught.exception.status_code)

    def test_load_returns_saved_payload(self) -> None:
        payload = {"videoId": "v1", "lines": [{"startMs": 0, "endMs": 1, "text": "하하"}]}
        with mock.patch.object(service.store, "get_json", return_value=payload):
            self.assertEqual(payload, service.load_transcript("v1"))


class DeleteDraftTest(unittest.TestCase):
    def test_deletes_latest_draft_only(self) -> None:
        with mock.patch.object(service.store, "delete") as removed:
            response = service.delete_project("v1")
        self.assertEqual(204, response.status_code)
        removed.assert_called_once_with("edit-projects/v1/latest.json")

    def test_deleting_a_missing_draft_still_succeeds(self) -> None:
        # 목록을 보고 눌렀는데 그 사이 다른 가족이 지웠을 수 있다. 사용자가 원한
        # 상태(초안 없음)가 이뤄졌으므로 오류로 돌려주지 않는다.
        with mock.patch.object(service.store, "delete", return_value=None):
            self.assertEqual(204, service.delete_project("gone").status_code)


if __name__ == "__main__":
    unittest.main()
