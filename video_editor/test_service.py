from __future__ import annotations

import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

import jwt
from fastapi import HTTPException

from pathlib import Path

from video_editor import service
from video_editor.analysis_jobs import (
    AnalysisJob,
    AnalysisJobManager,
    AnalysisQueueFull,
)
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


class AnalysisQueueLimitTest(unittest.TestCase):
    """대기 줄 상한.

    작업자가 하나뿐인데 상한이 없으면 뒤쪽 작업은 차례가 올 때까지 기다리는
    동안 원본 presigned URL(백엔드 기본 5분)이 만료되어, 오래 기다린 끝에
    내려받기부터 실패한다. 기다리게 하는 대신 지금 거절한다.
    """

    def _manager(self, max_waiting: int = 2) -> AnalysisJobManager:
        # 실제 분석은 돌리지 않는다 — 줄 세는 규칙만 본다.
        manager = AnalysisJobManager(save=lambda *_: None, max_waiting=max_waiting)
        manager._executor.shutdown(wait=False)
        manager._executor = mock.Mock()
        return manager

    def _fill(self, manager: AnalysisJobManager, count: int) -> None:
        for index in range(count):
            manager.submit(f"v{index}", Path(f"/tmp/v{index}.mp4"))

    def test_accepts_up_to_the_limit(self) -> None:
        """도는 것 하나는 상한에서 뺀다 — 세는 것은 '기다리는 줄'이다."""
        manager = self._manager(max_waiting=2)

        self._fill(manager, 3)

        self.assertEqual(3, len(manager._waiting_ids()))

    def test_rejects_once_the_line_is_full(self) -> None:
        manager = self._manager(max_waiting=2)
        self._fill(manager, 3)

        with self.assertRaises(AnalysisQueueFull):
            manager.submit("v-late", Path("/tmp/v-late.mp4"))

    def test_a_finished_job_frees_a_slot(self) -> None:
        """끝난 작업이 줄을 계속 차지하면 상한이 영구 잠금이 된다."""
        manager = self._manager(max_waiting=2)
        self._fill(manager, 3)
        manager._jobs["v0"].status = "done"

        manager.submit("v-next", Path("/tmp/v-next.mp4"))

        self.assertIn("v-next", manager._jobs)

    def test_resubmitting_a_running_video_does_not_take_a_slot(self) -> None:
        """같은 영상을 다시 눌러도 줄이 늘지 않아야 한다."""
        manager = self._manager(max_waiting=2)
        self._fill(manager, 3)

        manager.submit("v0", Path("/tmp/v0.mp4"))

        self.assertEqual(3, len(manager._waiting_ids()))

    def test_position_tells_how_many_are_ahead(self) -> None:
        """얼마나 기다려야 하는지 모르면 사용자는 그냥 다시 누른다."""
        manager = self._manager(max_waiting=4)
        self._fill(manager, 3)

        self.assertEqual(0, manager.position("v0"))
        self.assertEqual(2, manager.position("v2"))
        self.assertEqual(0, manager.position("v-unknown"))


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


class ComicPanelKeyTest(unittest.TestCase):
    """만화 그림이 PNG에서 JPEG으로 옮겨 가도 옛 만화가 사라지지 않는다.

    운영에 있던 만화 일곱 장은 `panel.png`에 저장돼 있고 저장본(`panel.json`)에
    `panelKey`가 없다. 새 코드가 JPEG 자리만 보면 그 일곱 장이 전부 "불러오지
    못했어요"가 된다 — 다시 그리게 하면 그림값이 또 든다.
    """

    def test_new_comics_are_stored_as_jpeg(self) -> None:
        self.assertTrue(service._comic_panel_key("v1").endswith("/panel.jpg"))

    def test_a_saved_comic_is_read_from_the_key_it_recorded(self) -> None:
        saved = {"panelKey": "comic/v1/panel.jpg"}
        self.assertEqual(
            service._comic_stored_panel_key("v1", saved), "comic/v1/panel.jpg"
        )

    def test_a_comic_made_before_the_switch_still_resolves_to_its_png(self) -> None:
        # panelKey가 없는 저장본 = JPEG 전환 이전에 만든 만화.
        self.assertEqual(
            service._comic_stored_panel_key("v1", {"savedAt": "2026-08-05T21:25:00Z"}),
            "comic/v1/panel.png",
        )

    def test_a_missing_save_record_falls_back_to_the_png_slot(self) -> None:
        self.assertEqual(
            service._comic_stored_panel_key("v1", None), "comic/v1/panel.png"
        )


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


class ComicScriptNotificationTest(unittest.TestCase):
    """1단계가 끝나면 요청자에게 알림이 나가야 한다.

    구성은 동기 응답이지만 모델 호출이 20초 가까이 걸린다. 그 사이 화면을
    벗어난 사용자에게는 알림이 대사가 준비된 것을 아는 유일한 통로다.
    """

    def _request(self, subject: str | None):
        token = (
            jwt.encode({"sub": subject}, "test-only", algorithm="HS256")
            if subject is not None
            else None
        )
        headers = {"authorization": f"Bearer {token}"} if token else {}
        return mock.Mock(headers=headers)

    def _script_request(self):
        return service.ComicScriptRequest(
            videoUrl="https://storage.example/v1.mp4",
            lines=[{"startMs": 0, "endMs": 1000, "text": "하하"}],
        )

    def test_notifies_requester_after_script_is_built(self) -> None:
        script = {"cuts": [{"caption": "하하"}], "characters": [], "setting": {}}
        with mock.patch.object(service.backend_access, "can_access_video", return_value=True), \
             mock.patch.object(service.comic, "build_script", return_value=script), \
             mock.patch.object(service.store, "put"), \
             mock.patch.object(service.backend_events, "comic_script_ready") as notified:
            response = service.comic_script(
                "v1", self._script_request(), self._request("user-1"))

        self.assertEqual(script["cuts"], response["cuts"])
        notified.assert_called_once_with("v1", "user-1")

    def test_storage_failure_still_notifies(self) -> None:
        # 시트를 못 남겨도 대사는 손에 들어왔다 — 알리지 않으면 화면을 벗어난
        # 사용자는 실패한 줄 알고 처음부터 다시 부른다.
        script = {"cuts": [{"caption": "하하"}], "characters": [], "setting": {}}
        with mock.patch.object(service.backend_access, "can_access_video", return_value=True), \
             mock.patch.object(service.comic, "build_script", return_value=script), \
             mock.patch.object(service.store, "put", side_effect=OSError("disk")), \
             mock.patch.object(service.backend_events, "comic_script_ready") as notified:
            service.comic_script("v1", self._script_request(), self._request("user-1"))

        notified.assert_called_once_with("v1", "user-1")

    def test_failed_script_does_not_notify(self) -> None:
        with mock.patch.object(service.backend_access, "can_access_video", return_value=True), \
             mock.patch.object(
                 service.comic, "build_script",
                 side_effect=service.comic.ComicError("gemini down")), \
             mock.patch.object(service.backend_events, "comic_script_ready") as notified:
            with self.assertRaises(HTTPException) as caught:
                service.comic_script("v1", self._script_request(), self._request("user-1"))

        self.assertEqual(502, caught.exception.status_code)
        notified.assert_not_called()


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
