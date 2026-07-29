"""Serve live YOLO frames and servo telemetry on a small local web dashboard."""

from __future__ import annotations

from collections import deque
from datetime import datetime, timezone
from functools import partial
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time
from typing import Any, BinaryIO
from urllib.parse import urlparse


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


class DashboardTelemetry:
    """Thread-safe latest-value store shared by YOLO, MQTT, and HTTP threads."""

    def __init__(
        self,
        *,
        log_path: Path | None = None,
        max_events: int = 240,
        event_interval_seconds: float = 0.25,
    ) -> None:
        self._condition = threading.Condition()
        self._vision: dict[str, Any] | None = None
        self._servo: dict[str, Any] | None = None
        self._events: deque[dict[str, Any]] = deque(maxlen=max_events)
        self._jpeg: bytes | None = None
        self._frame_sequence = 0
        self._last_vision_event_at = float("-inf")
        self._event_interval_seconds = event_interval_seconds
        self._started_at = utc_now()
        self._log_file: BinaryIO | None = None

        if log_path is not None:
            resolved = log_path.expanduser().resolve()
            resolved.parent.mkdir(parents=True, exist_ok=True)
            self._log_file = resolved.open("ab", buffering=0)

    @staticmethod
    def _event_from_payload(source: str, payload: dict[str, Any]) -> dict[str, Any]:
        return {
            "recorded_at": utc_now(),
            "source": source,
            "state": payload.get("state"),
            "direction": payload.get("direction"),
            "command_x": payload.get("command_x"),
            "command_y": payload.get("command_y"),
            "target_ids": payload.get("target_ids", []),
            "target_count": payload.get("target_count"),
            "objects": payload.get("objects", []),
            "group_box": payload.get("group_box"),
            "frame_width": payload.get("frame_width"),
            "frame_height": payload.get("frame_height"),
            "center_x": payload.get("center_x"),
            "center_y": payload.get("center_y"),
            "error_x": payload.get("error_x"),
            "error_y": payload.get("error_y"),
            "pan_deg": payload.get("pan_deg"),
            "tilt_deg": payload.get("tilt_deg"),
            "target_pan_deg": payload.get("target_pan_deg"),
            "target_tilt_deg": payload.get("target_tilt_deg"),
            "hardware_enabled": payload.get("hardware_enabled"),
        }

    def _append_event(self, source: str, payload: dict[str, Any]) -> None:
        event = self._event_from_payload(source, payload)
        self._events.append(event)
        if self._log_file is not None:
            encoded = (
                json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
            ).encode("utf-8")
            self._log_file.write(encoded)

    def update_vision(
        self,
        payload: dict[str, Any],
        jpeg: bytes,
        *,
        now_monotonic: float | None = None,
    ) -> None:
        now = time.monotonic() if now_monotonic is None else now_monotonic
        with self._condition:
            self._vision = dict(payload)
            self._jpeg = jpeg
            self._frame_sequence += 1
            if now - self._last_vision_event_at >= self._event_interval_seconds:
                self._append_event("vision", payload)
                self._last_vision_event_at = now
            self._condition.notify_all()

    def update_servo(self, payload: dict[str, Any]) -> None:
        with self._condition:
            self._servo = dict(payload)
            self._append_event("servo", payload)
            self._condition.notify_all()

    def snapshot(self) -> dict[str, Any]:
        with self._condition:
            return {
                "server_time": utc_now(),
                "started_at": self._started_at,
                "vision": dict(self._vision) if self._vision is not None else None,
                "servo": dict(self._servo) if self._servo is not None else None,
                "events": list(self._events),
                "frame_sequence": self._frame_sequence,
            }

    def wait_for_jpeg(
        self,
        previous_sequence: int,
        timeout: float = 5.0,
    ) -> tuple[int, bytes | None]:
        with self._condition:
            self._condition.wait_for(
                lambda: self._frame_sequence > previous_sequence,
                timeout=timeout,
            )
            return self._frame_sequence, self._jpeg

    def close(self) -> None:
        with self._condition:
            if self._log_file is not None:
                self._log_file.close()
                self._log_file = None
            self._condition.notify_all()


class DashboardRequestHandler(BaseHTTPRequestHandler):
    server_version = "WilliamJamesServoDashboard/1.0"

    def __init__(
        self,
        *args: Any,
        telemetry: DashboardTelemetry,
        static_dir: Path,
        **kwargs: Any,
    ) -> None:
        self.telemetry = telemetry
        self.static_dir = static_dir
        super().__init__(*args, **kwargs)

    def log_message(self, format: str, *args: Any) -> None:
        del format, args

    def _send_headers(
        self,
        status: HTTPStatus,
        content_type: str,
        content_length: int | None = None,
    ) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; img-src 'self'; "
            "script-src 'self'; style-src 'self'; connect-src 'self'",
        )
        if content_length is not None:
            self.send_header("Content-Length", str(content_length))
        self.end_headers()

    def _send_json(self, payload: dict[str, Any]) -> None:
        body = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        self._send_headers(HTTPStatus.OK, "application/json; charset=utf-8", len(body))
        self.wfile.write(body)

    def _send_static(self, filename: str, content_type: str) -> None:
        path = self.static_dir / filename
        try:
            body = path.read_bytes()
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self._send_headers(HTTPStatus.OK, content_type, len(body))
        self.wfile.write(body)

    def _stream_mjpeg(self) -> None:
        self._send_headers(
            HTTPStatus.OK,
            "multipart/x-mixed-replace; boundary=frame",
        )
        sequence = -1
        try:
            while True:
                sequence, jpeg = self.telemetry.wait_for_jpeg(sequence)
                if jpeg is None:
                    continue
                self.wfile.write(b"--frame\r\n")
                self.wfile.write(b"Content-Type: image/jpeg\r\n")
                self.wfile.write(f"Content-Length: {len(jpeg)}\r\n\r\n".encode("ascii"))
                self.wfile.write(jpeg)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/":
            self._send_static("index.html", "text/html; charset=utf-8")
        elif path == "/styles.css":
            self._send_static("styles.css", "text/css; charset=utf-8")
        elif path == "/app.js":
            self._send_static("app.js", "text/javascript; charset=utf-8")
        elif path == "/api/state":
            self._send_json(self.telemetry.snapshot())
        elif path == "/healthz":
            snapshot = self.telemetry.snapshot()
            self._send_json(
                {
                    "status": "ok",
                    "vision_available": snapshot["vision"] is not None,
                    "servo_available": snapshot["servo"] is not None,
                }
            )
        elif path == "/stream.mjpg":
            self._stream_mjpeg()
        else:
            self.send_error(HTTPStatus.NOT_FOUND)


class ServoDashboard:
    """Manage the local MQTT subscriber and HTTP dashboard server."""

    def __init__(
        self,
        *,
        host: str,
        port: int,
        device_id: str,
        mqtt_host: str,
        mqtt_port: int,
        mqtt_username: str | None = None,
        mqtt_password: str | None = None,
        log_path: Path | None = None,
        jpeg_width: int = 960,
        jpeg_quality: int = 72,
        frame_interval_seconds: float = 0.2,
    ) -> None:
        try:
            import paho.mqtt.client as mqtt
        except ImportError as exc:
            raise SystemExit(
                "paho-mqtt is missing. Install requirements-autoframe-jetson.txt."
            ) from exc

        self.host = host
        self.port = port
        self.jpeg_width = jpeg_width
        self.jpeg_quality = jpeg_quality
        self.frame_interval_seconds = frame_interval_seconds
        self._last_frame_at = float("-inf")
        self.telemetry = DashboardTelemetry(log_path=log_path)
        static_dir = Path(__file__).resolve().parent / "servo_dashboard_web"
        handler = partial(
            DashboardRequestHandler,
            telemetry=self.telemetry,
            static_dir=static_dir,
        )
        self._http = ThreadingHTTPServer((host, port), handler)
        self._http.daemon_threads = True
        self._http_thread = threading.Thread(
            target=self._http.serve_forever,
            name="servo-dashboard-http",
            daemon=True,
        )

        self._mqtt = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"{device_id}-servo-dashboard",
            protocol=mqtt.MQTTv311,
        )
        if mqtt_username:
            self._mqtt.username_pw_set(mqtt_username, mqtt_password)
        self._servo_topic = (
            f"homecam/v2/{device_id}/control/framing/status"
        )
        self._mqtt.on_connect = self._on_connect
        self._mqtt.on_message = self._on_message
        self._mqtt.connect(mqtt_host, mqtt_port, keepalive=60)

    def _on_connect(
        self,
        client: Any,
        userdata: Any,
        connect_flags: Any,
        reason_code: Any,
        properties: Any,
    ) -> None:
        del userdata, connect_flags, properties
        if not reason_code.is_failure:
            client.subscribe(self._servo_topic, qos=0)

    def _on_message(self, client: Any, userdata: Any, message: Any) -> None:
        del client, userdata
        try:
            payload = json.loads(message.payload.decode("utf-8"))
            if isinstance(payload, dict):
                self.telemetry.update_servo(payload)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return

    def start(self) -> None:
        self._mqtt.loop_start()
        self._http_thread.start()
        print(f"Servo dashboard: http://{self.host}:{self.port}")

    def update(
        self,
        payload: dict[str, Any],
        annotated_frame: Any,
        *,
        now_monotonic: float | None = None,
    ) -> bool:
        now = time.monotonic() if now_monotonic is None else now_monotonic
        if now - self._last_frame_at < self.frame_interval_seconds:
            return False

        import cv2

        height, width = annotated_frame.shape[:2]
        frame = annotated_frame
        if width > self.jpeg_width:
            ratio = self.jpeg_width / width
            frame = cv2.resize(
                annotated_frame,
                (self.jpeg_width, max(1, round(height * ratio))),
                interpolation=cv2.INTER_AREA,
            )
        ok, encoded = cv2.imencode(
            ".jpg",
            frame,
            [cv2.IMWRITE_JPEG_QUALITY, self.jpeg_quality],
        )
        if not ok:
            return False
        self.telemetry.update_vision(
            payload,
            encoded.tobytes(),
            now_monotonic=now,
        )
        self._last_frame_at = now
        return True

    def close(self) -> None:
        self._http.shutdown()
        self._http.server_close()
        self._mqtt.disconnect()
        self._mqtt.loop_stop()
        self.telemetry.close()
