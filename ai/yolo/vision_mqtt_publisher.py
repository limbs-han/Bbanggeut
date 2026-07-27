"""Publish the latest YOLO auto-framing state to MQTT."""

from __future__ import annotations

import json
import threading
from typing import Any


class VisionMqttPublisher:
    def __init__(
        self,
        *,
        host: str,
        port: int,
        device_id: str,
        username: str | None = None,
        password: str | None = None,
        topic: str | None = None,
        control_topic: str | None = None,
        connect_timeout: float = 5.0,
    ) -> None:
        try:
            import paho.mqtt.client as mqtt
        except ImportError as exc:
            raise SystemExit(
                "MQTT package is missing. Install requirements-autoframe-jetson.txt."
            ) from exc

        self._device_id = device_id
        self._topic = topic or f"homecam/v1/{device_id}/ai/vision/state"
        self._control_topic = control_topic or (
            f"homecam/v1/{device_id}/control/framing/target"
        )
        self._status_topic = f"homecam/v1/{device_id}/ai/vision/status"
        self._connected = threading.Event()
        self._connect_error: str | None = None
        self._warned_disconnected = False

        self._client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"{device_id}-yolo",
            protocol=mqtt.MQTTv311,
        )
        if username:
            self._client.username_pw_set(username, password)
        self._client.will_set(
            self._status_topic,
            payload=json.dumps(
                {"device_id": device_id, "component": "yolo", "status": "offline"}
            ),
            qos=1,
            retain=True,
        )
        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect

        try:
            self._client.connect(host, port, keepalive=60)
            self._client.loop_start()
            if not self._connected.wait(connect_timeout):
                raise RuntimeError("connection timed out")
            if self._connect_error:
                raise RuntimeError(self._connect_error)
        except Exception as exc:
            try:
                self._client.loop_stop()
            except Exception:
                pass
            raise SystemExit(
                f"Could not connect to MQTT broker {host}:{port}: {exc}"
            ) from exc

        print(f"Vision MQTT: {self._topic}")
        print(f"Framing target MQTT: {self._control_topic}")

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
        self._connect_error = None
        self._warned_disconnected = False
        client.publish(
            self._status_topic,
            payload=json.dumps(
                {"device_id": self._device_id, "component": "yolo", "status": "online"}
            ),
            qos=1,
            retain=True,
        )
        self._connected.set()

    def _on_disconnect(
        self,
        client: Any,
        userdata: Any,
        disconnect_flags: Any,
        reason_code: Any,
        properties: Any,
    ) -> None:
        del client, userdata, disconnect_flags, properties
        if reason_code.is_failure:
            self._connected.clear()

    def publish_state(self, payload: dict[str, Any]) -> bool:
        if not self._connected.is_set():
            if not self._warned_disconnected:
                print("Vision MQTT disconnected; tracking continues without publishing.")
                self._warned_disconnected = True
            return False
        state_message = self._client.publish(
            self._topic,
            payload=json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            qos=0,
            retain=False,
        )
        control_message = self._client.publish(
            self._control_topic,
            payload=json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            qos=0,
            retain=False,
        )
        return state_message.rc == 0 and control_message.rc == 0

    def close(self) -> None:
        if self._connected.is_set():
            message = self._client.publish(
                self._status_topic,
                payload=json.dumps(
                    {
                        "device_id": self._device_id,
                        "component": "yolo",
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
