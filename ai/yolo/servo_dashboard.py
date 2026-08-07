"""Serve live YOLO frames and servo telemetry on a small local web dashboard."""

from __future__ import annotations

from collections import deque
from datetime import datetime, timezone
from functools import partial
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import threading
import time
from typing import Any, BinaryIO, Callable
from urllib.parse import urlparse
import uuid

# The trigger writer lives with the audio detectors. Importing it keeps the
# button on the exact format the uploader already consumes; a second writer
# here would be a second thing to keep in step.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "yamnet"))
from audio_event_trigger import (  # noqa: E402
    write_audio_event_trigger as _write_audio_event_trigger,
)


def _isoformat(moment: datetime) -> str:
    return moment.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def utc_now() -> str:
    return _isoformat(datetime.now(timezone.utc))


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
        self._laughter: dict[str, Any] | None = None
        self._yamnet: dict[str, Any] | None = None
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
            "recorded_at": payload.get("recorded_at") or utc_now(),
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
            "event_id": payload.get("event_id"),
            "occurred_at": payload.get("occurred_at"),
            "confidence": payload.get("confidence"),
            "class_name": payload.get("class_name"),
            "upload_status": payload.get("upload_status"),
            "detail": payload.get("detail"),
            "attempts": payload.get("attempts"),
            "retry_delay_seconds": payload.get("retry_delay_seconds"),
            "http_status": payload.get("http_status"),
            "video_id": payload.get("video_id"),
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

    def update_laughter(self, payload: dict[str, Any]) -> None:
        with self._condition:
            merged: dict[str, Any] = {}
            if (
                self._laughter is not None
                and self._laughter.get("event_id") == payload.get("event_id")
            ):
                merged.update(self._laughter)
            merged.update(
                {
                    key: value
                    for key, value in payload.items()
                    if value is not None
                }
            )
            self._laughter = merged
            self._append_event("laughter", merged)
            self._condition.notify_all()

    def update_yamnet(self, payload: dict[str, Any]) -> None:
        with self._condition:
            self._yamnet = dict(payload)
            self._condition.notify_all()

    def snapshot(self) -> dict[str, Any]:
        with self._condition:
            return {
                "server_time": utc_now(),
                "started_at": self._started_at,
                "vision": dict(self._vision) if self._vision is not None else None,
                "servo": dict(self._servo) if self._servo is not None else None,
                "laughter": (
                    dict(self._laughter) if self._laughter is not None else None
                ),
                "yamnet": (
                    dict(self._yamnet) if self._yamnet is not None else None
                ),
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


class LaughterEventDirectoryMonitor:
    """Convert local laughter trigger and upload markers into telemetry."""

    _SUFFIXES = (
        ".trigger.json",
        ".upload-status.json",
        ".uploaded.json",
        ".merged.json",
        ".upload-blocked.json",
    )

    def __init__(
        self,
        event_dir: Path,
        telemetry: DashboardTelemetry,
        *,
        poll_seconds: float = 0.25,
    ) -> None:
        self.event_dir = event_dir.expanduser().resolve()
        self.telemetry = telemetry
        self.poll_seconds = poll_seconds
        self._seen_versions: dict[Path, tuple[int, int]] = {}
        self._seen_history_entries: dict[Path, set[tuple[Any, ...]]] = {}
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name="laughter-event-monitor",
            daemon=True,
        )

    @staticmethod
    def _event_id(path: Path) -> str:
        for suffix in LaughterEventDirectoryMonitor._SUFFIXES:
            if path.name.endswith(suffix):
                return path.name.removesuffix(suffix)
        return path.stem

    @staticmethod
    def _normalize(path: Path, payload: dict[str, Any]) -> dict[str, Any]:
        event_id = str(payload.get("eventId") or LaughterEventDirectoryMonitor._event_id(path))
        if path.name.endswith(".trigger.json"):
            status = "DETECTED"
            detail = "웃음 신호 감지"
        elif path.name.endswith(".uploaded.json"):
            status = "UPLOADED"
            detail = "영상 업로드 완료"
        elif path.name.endswith(".merged.json"):
            status = "MERGED"
            detail = "인접 웃음 이벤트와 영상 병합"
        elif path.name.endswith(".upload-blocked.json"):
            status = "BLOCKED"
            detail = str(payload.get("reason") or "업로드 차단")
        else:
            status = str(payload.get("status") or "UNKNOWN")
            detail = str(payload.get("detail") or "")
        return {
            "recorded_at": payload.get("updatedAt") or payload.get("occurredAt"),
            "state": status,
            "upload_status": status,
            "event_id": event_id,
            "occurred_at": payload.get("occurredAt"),
            "confidence": payload.get("confidence"),
            "class_name": payload.get("className"),
            "detail": detail,
            "attempts": payload.get("attempts"),
            "retry_delay_seconds": payload.get("retryDelaySeconds"),
            "http_status": payload.get("httpStatus"),
            "video_id": payload.get("videoId"),
        }

    def scan_once(self) -> None:
        try:
            self.event_dir.mkdir(parents=True, exist_ok=True)
            paths = sorted(
                (
                    path
                    for suffix in self._SUFFIXES
                    for path in self.event_dir.glob(f"*{suffix}")
                ),
                key=lambda path: path.stat().st_mtime_ns,
            )
        except OSError:
            return
        for path in paths:
            try:
                stat = path.stat()
                version = (stat.st_mtime_ns, stat.st_size)
                if self._seen_versions.get(path) == version:
                    continue
                payload = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(payload, dict):
                    continue
                history = payload.get("history")
                if path.name.endswith(".upload-status.json") and isinstance(
                    history, list
                ):
                    for item in history:
                        if isinstance(item, dict):
                            entry_key = (
                                item.get("updatedAt"),
                                item.get("status"),
                                item.get("detail"),
                            )
                            seen_entries = self._seen_history_entries.setdefault(
                                path, set()
                            )
                            if entry_key in seen_entries:
                                continue
                            self.telemetry.update_laughter(
                                self._normalize(
                                    path,
                                    {
                                        "eventId": payload.get("eventId"),
                                        **item,
                                    },
                                )
                            )
                            seen_entries.add(entry_key)
                else:
                    self.telemetry.update_laughter(self._normalize(path, payload))
                self._seen_versions[path] = version
            except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                continue

    def _run(self) -> None:
        while not self._stop.wait(self.poll_seconds):
            self.scan_once()

    def start(self) -> None:
        self.scan_once()
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join(timeout=max(1.0, self.poll_seconds * 2))


class YamnetDiagnosticsMonitor:
    """Tail YAMNet inference JSONL and expose its latest score."""

    def __init__(
        self,
        path: Path,
        telemetry: DashboardTelemetry,
        *,
        poll_seconds: float = 0.25,
    ) -> None:
        self.path = path.expanduser().resolve()
        self.telemetry = telemetry
        self.poll_seconds = poll_seconds
        self._offset = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run,
            name="yamnet-diagnostics-monitor",
            daemon=True,
        )

    @staticmethod
    def _normalize(payload: dict[str, Any]) -> dict[str, Any]:
        return {
            "observed_at": payload.get("observedAt"),
            "status": payload.get("status") or "READY",
            "detail": payload.get("detail"),
            "top_class": payload.get("topClass"),
            "top_score": payload.get("topScore"),
            "score": payload.get("selectedScore"),
            "class_name": payload.get("selectedClass"),
            "aggregation": payload.get("selectedAggregation"),
            "threshold": payload.get("threshold"),
            "positive_streak": payload.get("positiveStreak"),
            "would_trigger": payload.get("wouldTrigger"),
            "rms": payload.get("rms"),
            "inference_ms": payload.get("inferenceMs"),
        }

    def scan_once(self) -> None:
        try:
            size = self.path.stat().st_size
            if size < self._offset:
                self._offset = 0
            with self.path.open("r", encoding="utf-8") as stream:
                stream.seek(self._offset)
                lines = []
                while True:
                    line_start = stream.tell()
                    line = stream.readline()
                    if not line:
                        break
                    if not line.endswith("\n"):
                        self._offset = line_start
                        break
                    lines.append(line)
                    self._offset = stream.tell()
        except (OSError, UnicodeDecodeError):
            return

        for line in lines:
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(payload, dict):
                self.telemetry.update_yamnet(self._normalize(payload))

    def _run(self) -> None:
        while not self._stop.wait(self.poll_seconds):
            self.scan_once()

    def start(self) -> None:
        self.scan_once()
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join(timeout=max(1.0, self.poll_seconds * 2))


class ManualClipRecorder:
    """Turn dashboard button presses into ordinary laughter triggers.

    The trigger format carries a moment plus a window, so a press-and-release
    recording is expressible without any new contract: the moment is the start
    press and `postSeconds` is however long the user held it. The uploader,
    backend and app therefore need no change at all.

    The trigger is written on stop, never on start. A trigger that named a
    window still being recorded would sit in the uploader's scan failing
    coverage every second until the recording caught up.
    """

    # The clip carries one second from before the press. Someone reaches for
    # the button *because* something happened, and the start of the laugh is
    # in that reach.
    PRE_SECONDS = 1.0
    # A double-tap would otherwise ask for a zero-length window, which the
    # uploader rejects outright.
    MINIMUM_POST_SECONDS = 5.0
    # A session nobody stops would grow without limit; nothing in the upload
    # path caps clip size. Ten minutes is about 190MB at the recorder's
    # bitrate, which the event budget can absorb.
    MAXIMUM_POST_SECONDS = 600.0
    QUICK_POST_SECONDS = 120.0

    def __init__(
        self,
        event_dir: Path,
        *,
        now: Callable[[], datetime] | None = None,
        write_trigger: Callable[..., Path] | None = None,
    ) -> None:
        self.event_dir = event_dir.expanduser().resolve()
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._write_trigger = write_trigger or _write_audio_event_trigger
        self._lock = threading.Lock()
        self._started_at: datetime | None = None

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            started_at = self._started_at
        if started_at is None:
            return {"recording": False}
        elapsed = (self._now() - started_at).total_seconds()
        return {
            "recording": True,
            "startedAt": _isoformat(started_at),
            "elapsedSeconds": round(max(0.0, elapsed), 1),
            "maximumSeconds": self.MAXIMUM_POST_SECONDS,
        }

    def start(self) -> dict[str, Any]:
        with self._lock:
            if self._started_at is not None:
                # Report the running session rather than restarting it. A
                # second press is far more likely to be a double tap than a
                # request to discard what is already being recorded.
                already = self._started_at
                return {
                    "status": "already-recording",
                    "startedAt": _isoformat(already),
                }
            self._started_at = self._now()
            return {"status": "recording", "startedAt": _isoformat(self._started_at)}

    def stop(self) -> dict[str, Any]:
        with self._lock:
            started_at = self._started_at
            self._started_at = None
        if started_at is None:
            return {"status": "not-recording"}
        held = (self._now() - started_at).total_seconds()
        post_seconds = min(
            self.MAXIMUM_POST_SECONDS,
            max(self.MINIMUM_POST_SECONDS, held),
        )
        return self._write(started_at, post_seconds, "start-stop")

    def capture_quick(self) -> dict[str, Any]:
        """Record forward from now for the fixed quick-button window."""

        return self._write(self._now(), self.QUICK_POST_SECONDS, "quick")

    def expire_if_overrun(self) -> dict[str, Any] | None:
        """Finalize a session that has run past the cap, if one has."""

        with self._lock:
            started_at = self._started_at
            if started_at is None:
                return None
            if (self._now() - started_at).total_seconds() < self.MAXIMUM_POST_SECONDS:
                return None
            self._started_at = None
        return self._write(started_at, self.MAXIMUM_POST_SECONDS, "auto-stop")

    def _write(
        self,
        occurred_at: datetime,
        post_seconds: float,
        reason: str,
    ) -> dict[str, Any]:
        event_id = str(uuid.uuid4())
        self._write_trigger(
            self.event_dir,
            event_id=event_id,
            # LAUGHTER, not MANUAL. The backend treats MANUAL as something a
            # person uploaded and stays silent about it; only the detection
            # types produce the "웃음 영상이 도착했어요" arrival notice.
            event_type="LAUGHTER",
            occurred_at=occurred_at,
            confidence=1.0,
            class_name="Manual",
            pre_seconds=self.PRE_SECONDS,
            post_seconds=post_seconds,
            metadata={
                # Marks the trigger as human-made: detector statistics must not
                # count it, and the uploader must not merge it with a clap.
                "source": "dashboard-button",
                "reason": reason,
            },
        )
        return {
            "status": "captured",
            "eventId": event_id,
            "occurredAt": _isoformat(occurred_at),
            "preSeconds": self.PRE_SECONDS,
            "postSeconds": round(post_seconds, 1),
        }


class DashboardRequestHandler(BaseHTTPRequestHandler):
    server_version = "WilliamJamesServoDashboard/1.0"

    def __init__(
        self,
        *args: Any,
        telemetry: DashboardTelemetry,
        static_dir: Path,
        manual_recorder: ManualClipRecorder | None = None,
        **kwargs: Any,
    ) -> None:
        self.telemetry = telemetry
        self.static_dir = static_dir
        self.manual_recorder = manual_recorder
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
        self._send_json_status(HTTPStatus.OK, payload)

    def _send_json_status(
        self,
        status: HTTPStatus,
        payload: dict[str, Any],
    ) -> None:
        body = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        self._send_headers(status, "application/json; charset=utf-8", len(body))
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
            snapshot = self.telemetry.snapshot()
            if self.manual_recorder is not None:
                # Finalizing here rather than on a timer keeps the recorder
                # free of its own thread: the dashboard page polls state
                # continuously while anyone is watching.
                self.manual_recorder.expire_if_overrun()
                snapshot["manualClip"] = self.manual_recorder.snapshot()
            self._send_json(snapshot)
        elif path == "/healthz":
            snapshot = self.telemetry.snapshot()
            yamnet = snapshot["yamnet"]
            self._send_json(
                {
                    "status": "ok",
                    "vision_available": snapshot["vision"] is not None,
                    "servo_available": snapshot["servo"] is not None,
                    "laughter_available": snapshot["laughter"] is not None,
                    "yamnet_available": (
                        yamnet is not None
                        and str(yamnet.get("status", "READY")).upper()
                        == "READY"
                    ),
                    "yamnet_status": (
                        str(yamnet.get("status", "UNAVAILABLE")).upper()
                        if yamnet is not None
                        else "UNAVAILABLE"
                    ),
                }
            )
        elif path == "/stream.mjpg":
            self._stream_mjpeg()
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if self.manual_recorder is None:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        # A form post from another origin would otherwise reach these routes
        # with no script involved, and the page has no session to check. The
        # dashboard binds to loopback, so this is a second line, not the only
        # one.
        if self.headers.get("X-Requested-With") != "servo-dashboard":
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        actions = {
            "/api/manual-clip/start": self.manual_recorder.start,
            "/api/manual-clip/stop": self.manual_recorder.stop,
            "/api/manual-clip/quick": self.manual_recorder.capture_quick,
        }
        action = actions.get(path)
        if action is None:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        try:
            self._send_json(action())
        except OSError as error:
            # The event directory can be full or read-only. Say so instead of
            # letting the handler raise and drop the connection.
            self._send_json_status(
                HTTPStatus.SERVICE_UNAVAILABLE,
                {"status": "failed", "detail": str(error)},
            )


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
        event_dir: Path | None = None,
        yamnet_diagnostics_path: Path | None = None,
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
        self._laughter_monitor = (
            LaughterEventDirectoryMonitor(event_dir, self.telemetry)
            if event_dir is not None
            else None
        )
        self._yamnet_monitor = (
            YamnetDiagnosticsMonitor(yamnet_diagnostics_path, self.telemetry)
            if yamnet_diagnostics_path is not None
            else None
        )
        static_dir = Path(__file__).resolve().parent / "servo_dashboard_web"
        # Without an event directory there is nowhere to put a trigger, so the
        # buttons are not offered at all rather than failing when pressed.
        self.manual_recorder = (
            ManualClipRecorder(event_dir) if event_dir is not None else None
        )
        handler = partial(
            DashboardRequestHandler,
            telemetry=self.telemetry,
            static_dir=static_dir,
            manual_recorder=self.manual_recorder,
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
        self._laughter_topic = (
            f"homecam/v2/{device_id}/ai/laughter/detected"
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
            client.subscribe(
                [(self._servo_topic, 0), (self._laughter_topic, 1)]
            )

    def _on_message(self, client: Any, userdata: Any, message: Any) -> None:
        del client, userdata
        try:
            payload = json.loads(message.payload.decode("utf-8"))
            if isinstance(payload, dict):
                if message.topic == self._laughter_topic:
                    self.telemetry.update_laughter(
                        {
                            "state": "DETECTED",
                            "recorded_at": payload.get("detected_at"),
                            "upload_status": "DETECTED",
                            "event_id": payload.get("event_id"),
                            "occurred_at": payload.get("detected_at"),
                            "confidence": payload.get("score"),
                            "class_name": payload.get("class_name"),
                            "detail": "YAMNet MQTT 웃음 신호",
                        }
                    )
                elif message.topic == self._servo_topic:
                    self.telemetry.update_servo(payload)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return

    def start(self) -> None:
        self._mqtt.loop_start()
        if self._laughter_monitor is not None:
            self._laughter_monitor.start()
        if self._yamnet_monitor is not None:
            self._yamnet_monitor.start()
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
        if self._laughter_monitor is not None:
            self._laughter_monitor.close()
        if self._yamnet_monitor is not None:
            self._yamnet_monitor.close()
        self._mqtt.disconnect()
        self._mqtt.loop_stop()
        self.telemetry.close()
