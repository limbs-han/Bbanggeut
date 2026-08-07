from __future__ import annotations

import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.request

from servo_dashboard import (
    DashboardRequestHandler,
    DashboardTelemetry,
    LaughterEventDirectoryMonitor,
    ManualClipRecorder,
    ThreadingHTTPServer,
    YamnetDiagnosticsMonitor,
)
from datetime import datetime, timedelta, timezone
from functools import partial


class DashboardTelemetryTests(unittest.TestCase):
    def test_snapshot_combines_vision_servo_and_events(self) -> None:
        telemetry = DashboardTelemetry(event_interval_seconds=0.25)
        telemetry.update_vision(
            {
                "state": "TRACKING",
                "direction": "RIGHT_DOWN",
                "center_x": 0.7,
                "center_y": 0.6,
                "error_x": 0.4,
                "error_y": 0.2,
            },
            b"jpeg",
            now_monotonic=1.0,
        )
        telemetry.update_servo(
            {
                "state": "TRACKING",
                "pan_deg": 3.5,
                "tilt_deg": 1.25,
                "hardware_enabled": True,
            }
        )

        snapshot = telemetry.snapshot()

        self.assertEqual(snapshot["vision"]["center_x"], 0.7)
        self.assertEqual(snapshot["servo"]["pan_deg"], 3.5)
        self.assertEqual([event["source"] for event in snapshot["events"]], [
            "vision",
            "servo",
        ])
        sequence, jpeg = telemetry.wait_for_jpeg(-1, timeout=0.01)
        self.assertEqual(sequence, 1)
        self.assertEqual(jpeg, b"jpeg")
        telemetry.close()

    def test_vision_events_are_rate_limited_but_latest_frame_updates(self) -> None:
        telemetry = DashboardTelemetry(event_interval_seconds=0.25)
        telemetry.update_vision({"frame_index": 1}, b"one", now_monotonic=1.0)
        telemetry.update_vision({"frame_index": 2}, b"two", now_monotonic=1.1)

        snapshot = telemetry.snapshot()

        self.assertEqual(snapshot["vision"]["frame_index"], 2)
        self.assertEqual(snapshot["frame_sequence"], 2)
        self.assertEqual(len(snapshot["events"]), 1)
        telemetry.close()

    def test_events_are_written_as_json_lines(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            log_path = Path(temp_dir) / "dashboard.jsonl"
            telemetry = DashboardTelemetry(log_path=log_path)
            telemetry.update_servo({"state": "HOLD", "pan_deg": 0.0})
            telemetry.close()

            records = [
                json.loads(line)
                for line in log_path.read_text(encoding="utf-8").splitlines()
            ]

        self.assertEqual(records[0]["source"], "servo")
        self.assertEqual(records[0]["state"], "HOLD")

    def test_laughter_state_keeps_detection_context_during_upload(self) -> None:
        telemetry = DashboardTelemetry()
        telemetry.update_laughter(
            {
                "state": "DETECTED",
                "event_id": "laugh-1",
                "occurred_at": "2026-07-30T01:00:00.000Z",
                "confidence": 0.81,
            }
        )
        telemetry.update_laughter(
            {
                "state": "RETRYING",
                "upload_status": "RETRYING",
                "event_id": "laugh-1",
                "detail": "HTTP 503",
                "attempts": 2,
            }
        )

        laughter = telemetry.snapshot()["laughter"]

        self.assertEqual(laughter["upload_status"], "RETRYING")
        self.assertEqual(laughter["confidence"], 0.81)
        self.assertEqual(laughter["attempts"], 2)
        telemetry.close()

    def test_event_directory_monitor_logs_trigger_and_upload_status(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            event_dir = Path(temp_dir)
            telemetry = DashboardTelemetry()
            monitor = LaughterEventDirectoryMonitor(event_dir, telemetry)
            (event_dir / "laugh-1.trigger.json").write_text(
                json.dumps(
                    {
                        "eventId": "laugh-1",
                        "occurredAt": "2026-07-30T01:00:00.000Z",
                        "confidence": 0.81,
                        "className": "Laughter",
                    }
                ),
                encoding="utf-8",
            )
            monitor.scan_once()
            (event_dir / "laugh-1.upload-status.json").write_text(
                json.dumps(
                    {
                        "eventId": "laugh-1",
                        "status": "UPLOADED",
                        "detail": "영상 업로드 완료",
                        "videoId": "video-1",
                        "history": [
                            {
                                "status": "BUILDING_CLIP",
                                "detail": "영상 생성 중",
                                "updatedAt": "2026-07-30T01:01:00.000Z",
                            },
                            {
                                "status": "UPLOADED",
                                "detail": "영상 업로드 완료",
                                "videoId": "video-1",
                                "updatedAt": "2026-07-30T01:02:00.000Z",
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )
            monitor.scan_once()
            monitor.scan_once()

            snapshot = telemetry.snapshot()

            self.assertEqual(snapshot["laughter"]["upload_status"], "UPLOADED")
            self.assertEqual(snapshot["laughter"]["confidence"], 0.81)
            self.assertEqual(snapshot["laughter"]["video_id"], "video-1")
            self.assertEqual(
                [event["upload_status"] for event in snapshot["events"]],
                ["DETECTED", "BUILDING_CLIP", "UPLOADED"],
            )
            monitor.close()
            telemetry.close()

    def test_yamnet_diagnostics_monitor_exposes_latest_inference(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            diagnostics_path = Path(temp_dir) / "yamnet.jsonl"
            telemetry = DashboardTelemetry()
            monitor = YamnetDiagnosticsMonitor(diagnostics_path, telemetry)
            diagnostics_path.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "observedAt": "2026-07-30T03:00:00.000Z",
                                "topClass": "Speech",
                                "topScore": 0.61,
                                "selectedAggregation": "mean",
                                "selectedScore": 0.008,
                                "selectedClass": "Laughter",
                                "threshold": 0.125,
                                "positiveStreak": 0,
                                "wouldTrigger": False,
                                "rms": 0.0748,
                                "inferenceMs": 58.0,
                            }
                        ),
                        json.dumps(
                            {
                                "observedAt": "2026-07-30T03:00:00.480Z",
                                "topClass": "Laughter",
                                "topScore": 0.71,
                                "selectedAggregation": "mean",
                                "selectedScore": 0.13,
                                "selectedClass": "Laughter",
                                "threshold": 0.125,
                                "positiveStreak": 1,
                                "wouldTrigger": False,
                                "rms": 0.0912,
                                "inferenceMs": 52.0,
                            }
                        ),
                        "",
                    ]
                ),
                encoding="utf-8",
            )

            monitor.scan_once()
            yamnet = telemetry.snapshot()["yamnet"]

            self.assertEqual(yamnet["top_class"], "Laughter")
            self.assertEqual(yamnet["score"], 0.13)
            self.assertEqual(yamnet["threshold"], 0.125)
            self.assertEqual(yamnet["positive_streak"], 1)
            self.assertEqual(yamnet["rms"], 0.0912)
            self.assertEqual(yamnet["status"], "READY")
            monitor.close()
            telemetry.close()

    def test_yamnet_diagnostics_monitor_exposes_degraded_status(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            diagnostics_path = Path(temp_dir) / "yamnet.jsonl"
            telemetry = DashboardTelemetry()
            monitor = YamnetDiagnosticsMonitor(diagnostics_path, telemetry)
            diagnostics_path.write_text(
                json.dumps(
                    {
                        "observedAt": "2026-07-30T03:00:00.000Z",
                        "status": "UNAVAILABLE",
                        "detail": "Readiness timed out; detector still running",
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            monitor.scan_once()
            yamnet = telemetry.snapshot()["yamnet"]

            self.assertEqual(yamnet["status"], "UNAVAILABLE")
            self.assertIn("timed out", yamnet["detail"])
            self.assertIsNone(yamnet["score"])

            with diagnostics_path.open("a", encoding="utf-8") as stream:
                stream.write(
                    json.dumps(
                        {
                            "observedAt": "2026-07-30T03:00:01.000Z",
                            "selectedScore": 0.02,
                            "threshold": 0.125,
                        }
                    )
                    + "\n"
                )
            monitor.scan_once()
            recovered = telemetry.snapshot()["yamnet"]

            self.assertEqual(recovered["status"], "READY")
            self.assertEqual(recovered["score"], 0.02)
            monitor.close()
            telemetry.close()


class FakeClock:
    def __init__(self) -> None:
        self.now = datetime(2026, 8, 7, 12, 0, tzinfo=timezone.utc)

    def __call__(self) -> datetime:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now = self.now + timedelta(seconds=seconds)


class ManualClipRecorderTests(unittest.TestCase):
    def _recorder(self, clock: FakeClock) -> tuple[ManualClipRecorder, list[dict]]:
        written: list[dict] = []

        def write_trigger(event_dir, **payload):
            written.append({"eventDir": event_dir, **payload})
            return Path(event_dir) / f"{payload['event_id']}.trigger.json"

        recorder = ManualClipRecorder(
            Path(tempfile.gettempdir()) / "wj-manual-clip-test",
            now=clock,
            write_trigger=write_trigger,
        )
        return recorder, written

    def test_stop_records_the_held_window_forward_from_the_start(self) -> None:
        clock = FakeClock()
        recorder, written = self._recorder(clock)
        started = clock.now

        recorder.start()
        clock.advance(42.0)
        result = recorder.stop()

        self.assertEqual(result["status"], "captured")
        self.assertEqual(len(written), 1)
        payload = written[0]
        self.assertEqual(payload["occurred_at"], started)
        self.assertEqual(payload["pre_seconds"], 1.0)
        self.assertEqual(payload["post_seconds"], 42.0)

    def test_trigger_is_written_only_on_stop(self) -> None:
        # A trigger naming a window still being recorded would fail coverage
        # in the uploader's scan every second until the recording caught up.
        clock = FakeClock()
        recorder, written = self._recorder(clock)

        recorder.start()
        clock.advance(30.0)

        self.assertEqual(written, [])

    def test_event_type_is_laughter_so_the_arrival_notice_fires(self) -> None:
        # MANUAL would be treated as a human upload and the backend stays
        # silent about those; only detection types notify.
        clock = FakeClock()
        recorder, written = self._recorder(clock)

        recorder.capture_quick()

        self.assertEqual(written[0]["event_type"], "LAUGHTER")
        self.assertEqual(written[0]["post_seconds"], 120.0)
        self.assertEqual(written[0]["metadata"]["source"], "dashboard-button")

    def test_double_tap_stop_still_produces_a_usable_window(self) -> None:
        clock = FakeClock()
        recorder, written = self._recorder(clock)

        recorder.start()
        result = recorder.stop()

        self.assertEqual(written[0]["post_seconds"], 5.0)
        self.assertEqual(result["postSeconds"], 5.0)

    def test_second_start_does_not_discard_the_running_session(self) -> None:
        clock = FakeClock()
        recorder, written = self._recorder(clock)

        first = recorder.start()
        clock.advance(10.0)
        second = recorder.start()
        clock.advance(10.0)
        recorder.stop()

        self.assertEqual(second["status"], "already-recording")
        self.assertEqual(second["startedAt"], first["startedAt"])
        self.assertEqual(written[0]["post_seconds"], 20.0)

    def test_a_forgotten_session_is_capped_not_left_running(self) -> None:
        clock = FakeClock()
        recorder, written = self._recorder(clock)

        recorder.start()
        clock.advance(ManualClipRecorder.MAXIMUM_POST_SECONDS + 120.0)
        expired = recorder.expire_if_overrun()

        self.assertIsNotNone(expired)
        self.assertEqual(
            written[0]["post_seconds"],
            ManualClipRecorder.MAXIMUM_POST_SECONDS,
        )
        self.assertFalse(recorder.snapshot()["recording"])

    def test_stop_without_start_writes_nothing(self) -> None:
        clock = FakeClock()
        recorder, written = self._recorder(clock)

        result = recorder.stop()

        self.assertEqual(result["status"], "not-recording")
        self.assertEqual(written, [])


class DashboardHttpTests(unittest.TestCase):
    def test_static_dashboard_exposes_yamnet_live_fields(self) -> None:
        static_dir = Path(__file__).resolve().parent / "servo_dashboard_web"
        html = (static_dir / "index.html").read_text(encoding="utf-8")
        script = (static_dir / "app.js").read_text(encoding="utf-8")

        for element_id in (
            "yamnet-status",
            "yamnet-score",
            "yamnet-threshold",
            "yamnet-rms",
            "yamnet-top-class",
            "yamnet-streak",
            "yamnet-inference",
        ):
            self.assertIn(f'id="{element_id}"', html)
            self.assertIn(f'"{element_id}"', script)
        self.assertIn("updateYamnet(payload.yamnet)", script)

    def test_manual_clip_buttons_write_a_real_trigger(self) -> None:
        telemetry = DashboardTelemetry()
        static_dir = Path(__file__).resolve().parent / "servo_dashboard_web"
        with tempfile.TemporaryDirectory() as root:
            event_dir = Path(root) / "events"
            recorder = ManualClipRecorder(event_dir)
            handler = partial(
                DashboardRequestHandler,
                telemetry=telemetry,
                static_dir=static_dir,
                manual_recorder=recorder,
            )
            server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            port = server.server_address[1]

            def post(path: str, with_header: bool = True):
                request = urllib.request.Request(
                    f"http://127.0.0.1:{port}{path}", method="POST"
                )
                if with_header:
                    request.add_header("X-Requested-With", "servo-dashboard")
                return urllib.request.urlopen(request, timeout=2)

            try:
                with post("/api/manual-clip/quick") as response:
                    captured = json.load(response)
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/api/state", timeout=2
                ) as response:
                    state = json.load(response)
                with post("/api/manual-clip/start") as response:
                    json.load(response)
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/api/state", timeout=2
                ) as response:
                    recording_state = json.load(response)
                with self.assertRaises(urllib.error.HTTPError) as forbidden:
                    post("/api/manual-clip/stop", with_header=False)
            finally:
                server.shutdown()
                server.server_close()
                telemetry.close()
                thread.join(timeout=2)

            triggers = sorted(event_dir.glob("*.trigger.json"))
            self.assertEqual(len(triggers), 1)
            payload = json.loads(triggers[0].read_text(encoding="utf-8"))

        self.assertEqual(captured["status"], "captured")
        self.assertEqual(payload["type"], "LAUGHTER")
        self.assertEqual(payload["preSeconds"], 1.0)
        self.assertEqual(payload["postSeconds"], 120.0)
        self.assertEqual(payload["metadata"]["source"], "dashboard-button")
        self.assertFalse(state["manualClip"]["recording"])
        self.assertTrue(recording_state["manualClip"]["recording"])
        # A cross-origin form post carries no custom header, and the page has
        # no session to check against.
        self.assertEqual(forbidden.exception.code, 403)

    def test_manual_clip_routes_are_absent_without_an_event_directory(self) -> None:
        telemetry = DashboardTelemetry()
        static_dir = Path(__file__).resolve().parent / "servo_dashboard_web"
        handler = partial(
            DashboardRequestHandler,
            telemetry=telemetry,
            static_dir=static_dir,
        )
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]

        try:
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/api/manual-clip/quick", method="POST"
            )
            request.add_header("X-Requested-With", "servo-dashboard")
            with self.assertRaises(urllib.error.HTTPError) as missing:
                urllib.request.urlopen(request, timeout=2)
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/api/state", timeout=2
            ) as response:
                state = json.load(response)
        finally:
            server.shutdown()
            server.server_close()
            telemetry.close()
            thread.join(timeout=2)

        self.assertEqual(missing.exception.code, 404)
        self.assertNotIn("manualClip", state)

    def test_static_dashboard_wires_the_manual_clip_controls(self) -> None:
        static_dir = Path(__file__).resolve().parent / "servo_dashboard_web"
        html = (static_dir / "index.html").read_text(encoding="utf-8")
        script = (static_dir / "app.js").read_text(encoding="utf-8")

        for element_id in ("manual-clip", "manual-quick", "manual-toggle", "manual-status"):
            self.assertIn(f'id="{element_id}"', html)
            self.assertIn(f'"{element_id}"', script)
        self.assertIn("updateManualClip(payload.manualClip)", script)
        self.assertIn('"X-Requested-With": "servo-dashboard"', script)

    def test_health_and_state_endpoints(self) -> None:
        telemetry = DashboardTelemetry()
        static_dir = Path(__file__).resolve().parent / "servo_dashboard_web"
        handler = partial(
            DashboardRequestHandler,
            telemetry=telemetry,
            static_dir=static_dir,
        )
        server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]

        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/healthz",
                timeout=2,
            ) as response:
                health = json.load(response)
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/api/state",
                timeout=2,
            ) as response:
                state = json.load(response)
            telemetry.update_yamnet(
                {
                    "status": "UNAVAILABLE",
                    "detail": "Readiness timed out",
                }
            )
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/healthz",
                timeout=2,
            ) as response:
                degraded_health = json.load(response)
            telemetry.update_yamnet({"status": "READY", "score": 0.01})
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/healthz",
                timeout=2,
            ) as response:
                ready_health = json.load(response)
        finally:
            server.shutdown()
            server.server_close()
            telemetry.close()
            thread.join(timeout=2)

        self.assertEqual(health["status"], "ok")
        self.assertFalse(health["vision_available"])
        self.assertFalse(health["laughter_available"])
        self.assertFalse(health["yamnet_available"])
        self.assertEqual(health["yamnet_status"], "UNAVAILABLE")
        self.assertFalse(degraded_health["yamnet_available"])
        self.assertEqual(degraded_health["yamnet_status"], "UNAVAILABLE")
        self.assertTrue(ready_health["yamnet_available"])
        self.assertEqual(ready_health["yamnet_status"], "READY")
        self.assertIsNone(state["servo"])
        self.assertIsNone(state["yamnet"])


if __name__ == "__main__":
    unittest.main()
