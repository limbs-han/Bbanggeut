"""Publish YAMNet laughter detections as versioned MQTT events."""

from __future__ import annotations

import json
import threading
import uuid
from datetime import datetime, timezone
from typing import Any


class MqttEventPublisher:
    """Small MQTT client used only when the detector enables MQTT."""

    def __init__(
        self,
        *,
        host: str,
        port: int,
        device_id: str,
        username: str | None = None,
        password: str | None = None,
        event_topic: str | None = None,
        connect_timeout: float = 5.0,
    ) -> None:
        try:
            import paho.mqtt.client as mqtt
        except ImportError as exc:
            raise SystemExit(
                "MQTT 패키지를 불러오지 못했습니다. 다음 명령을 실행하세요:\n"
                "python -m pip install 'paho-mqtt>=2,<3'"
            ) from exc

        self._device_id = device_id
        self._event_topic = event_topic or (
            f"homecam/v1/{device_id}/ai/laughter/detected"
        )
        self._status_topic = f"homecam/v1/{device_id}/ai/status"
        self._connected = threading.Event()
        self._connect_error: str | None = None

        self._client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"{device_id}-yamnet",
            protocol=mqtt.MQTTv311,
        )
        if username:
            self._client.username_pw_set(username, password)

        self._client.will_set(
            self._status_topic,
            payload=json.dumps(
                {"device_id": device_id, "component": "yamnet", "status": "offline"}
            ),
            qos=1,
            retain=True,
        )
        self._client.on_connect = self._on_connect
        self._client.on_connect_fail = self._on_connect_fail

        try:
            self._client.connect(host, port, keepalive=60)
            self._client.loop_start()
            if not self._connected.wait(connect_timeout):
                raise RuntimeError("연결 시간 초과")
            if self._connect_error:
                raise RuntimeError(self._connect_error)
        except Exception as exc:
            try:
                self._client.loop_stop()
            except Exception:
                pass
            raise SystemExit(
                f"MQTT 브로커에 연결하지 못했습니다: {host}:{port} ({exc})"
            ) from exc

        print(f"MQTT 연결 완료: {host}:{port}")
        print(f"MQTT 이벤트 토픽: {self._event_topic}")

    def _on_connect(
        self,
        client: Any,
        userdata: Any,
        connect_flags: Any,
        reason_code: Any,
        properties: Any,
    ) -> None:
        del userdata, connect_flags, properties
        if reason_code.is_failure:
            self._connect_error = str(reason_code)
            self._connected.set()
            return

        client.publish(
            self._status_topic,
            payload=json.dumps(
                {
                    "device_id": self._device_id,
                    "component": "yamnet",
                    "status": "online",
                }
            ),
            qos=1,
            retain=True,
        )
        self._connected.set()

    def _on_connect_fail(self, client: Any, userdata: Any) -> None:
        del client, userdata
        self._connect_error = "네트워크 연결 실패"
        self._connected.set()

    def publish_laughter(
        self,
        *,
        score: float,
        class_name: str,
        threshold: float,
        consecutive: int,
        monotonic_ns: int,
    ) -> str:
        event_id = str(uuid.uuid4())
        detected_at = (
            datetime.now(timezone.utc)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z")
        )
        payload = {
            "schema_version": "1.0",
            "event_id": event_id,
            "device_id": self._device_id,
            "event_type": "LAUGHTER",
            "detected_at": detected_at,
            "monotonic_ns": monotonic_ns,
            "score": round(score, 6),
            "class_name": class_name,
            "clip": {"pre_seconds": 60, "post_seconds": 60},
            "model": {
                "name": "YAMNet",
                "threshold": threshold,
                "consecutive": consecutive,
            },
        }
        message = self._client.publish(
            self._event_topic,
            payload=json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            qos=1,
            retain=False,
        )
        message.wait_for_publish(timeout=3.0)
        if not message.is_published():
            raise RuntimeError("MQTT 이벤트 발행 확인 시간이 초과되었습니다.")
        print(f"MQTT 이벤트 발행: event_id={event_id}")
        return event_id

    def close(self) -> None:
        if not self._connected.is_set():
            return

        message = self._client.publish(
            self._status_topic,
            payload=json.dumps(
                {
                    "device_id": self._device_id,
                    "component": "yamnet",
                    "status": "offline",
                }
            ),
            qos=1,
            retain=True,
        )
        try:
            message.wait_for_publish(timeout=1.0)
        except RuntimeError:
            pass
        self._client.disconnect()
        self._client.loop_stop()
