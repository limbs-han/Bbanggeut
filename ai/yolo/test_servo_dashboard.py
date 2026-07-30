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
    ThreadingHTTPServer,
)
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


class DashboardHttpTests(unittest.TestCase):
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
        finally:
            server.shutdown()
            server.server_close()
            telemetry.close()
            thread.join(timeout=2)

        self.assertEqual(health["status"], "ok")
        self.assertFalse(health["vision_available"])
        self.assertFalse(health["laughter_available"])
        self.assertIsNone(state["servo"])


if __name__ == "__main__":
    unittest.main()
