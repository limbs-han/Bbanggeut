from __future__ import annotations

from collections import OrderedDict
from datetime import datetime, timezone
import json
import logging
import queue
import re
import signal
import ssl
import threading
import time
from typing import Any
from uuid import UUID, uuid4

import paho.mqtt.client as mqtt

from .config import AgentConfig
from .stream import StreamManager
from .talkback import TalkbackManager


LOG = logging.getLogger("wj-device-agent")


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def isoformat(value: datetime | None = None) -> str:
    return (value or utc_now()).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_time(value: str) -> datetime:
    # Java Instant uses up to nanosecond precision, while the Python version
    # bundled with this JetPack accepts at most six fractional digits.
    normalized = re.sub(
        r"(\.\d{6})\d+(?=Z$|[+-]\d{2}:\d{2}$)",
        r"\1",
        value,
    )
    parsed = datetime.fromisoformat(normalized.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must include a timezone")
    return parsed.astimezone(timezone.utc)


class DeviceAgent:
    def __init__(self, config: AgentConfig) -> None:
        self.config = config
        self.streams = StreamManager(config)
        self.talkback = TalkbackManager(config)
        self.talkback_retries = 0
        self.commands: queue.Queue[dict[str, Any] | None] = queue.Queue(maxsize=100)
        self.stop_event = threading.Event()
        self.last_commands: OrderedDict[str, dict[str, Any]] = OrderedDict()
        self.current_context: dict[str, Any] | None = None
        self.client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=config.device_id,
            protocol=mqtt.MQTTv311,
        )
        self.client.username_pw_set(config.device_id, config.bearer_token)
        self.client.tls_set(
            ca_certs=str(config.mqtt_ca_cert),
            cert_reqs=ssl.CERT_REQUIRED,
            tls_version=ssl.PROTOCOL_TLS_CLIENT,
        )
        self.client.tls_insecure_set(False)
        self.client.reconnect_delay_set(min_delay=1, max_delay=60)
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect
        self.client.will_set(
            f"{config.topic_base}/status",
            json.dumps(self._status("OFFLINE", "CONNECTION_LOST")),
            qos=1,
            retain=True,
        )

    def run(self) -> None:
        worker = threading.Thread(target=self._command_worker, name="command-worker", daemon=True)
        monitor = threading.Thread(target=self._monitor, name="stream-monitor", daemon=True)
        heartbeat = threading.Thread(target=self._heartbeat_loop, name="heartbeat", daemon=True)
        worker.start()
        monitor.start()
        heartbeat.start()
        self.client.connect_async(self.config.mqtt_host, self.config.mqtt_port, keepalive=30)
        self.client.loop_start()
        LOG.info("기기 에이전트 시작: %s", self.config.device_id)
        self.stop_event.wait()
        self.commands.put(None)
        self.talkback.stop()
        self.streams.stop()
        if self.client.is_connected():
            self._publish("status", self._status("OFFLINE", "SERVICE_STOPPED"), 1, True)
            self.client.disconnect()
        self.client.loop_stop()

    def shutdown(self) -> None:
        self.stop_event.set()

    def _on_connect(self, client, userdata, flags, reason_code, properties) -> None:
        if reason_code != 0:
            LOG.warning("MQTT 연결 거부: %s", reason_code)
            return
        client.subscribe(f"{self.config.topic_base}/commands", qos=1)
        self._publish("status", self._status("ONLINE", "BOOT_COMPLETED"), 1, True)
        LOG.info("MQTT 연결 및 명령 구독 활성화 완료")

    def _on_disconnect(self, client, userdata, flags, reason_code, properties) -> None:
        if not self.stop_event.is_set():
            LOG.warning("MQTT 연결 해제: %s", reason_code)

    def _on_message(self, client, userdata, message) -> None:
        try:
            body = json.loads(message.payload.decode("utf-8"))
            if not isinstance(body, dict):
                raise ValueError("command must be an object")
            self.commands.put_nowait(body)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError, queue.Full) as error:
            LOG.warning("잘못된 MQTT 명령 무시: %s", type(error).__name__)

    def _command_worker(self) -> None:
        while not self.stop_event.is_set():
            command = self.commands.get()
            if command is None:
                return
            try:
                self._handle(command)
            except Exception as error:
                LOG.exception("명령 처리 실패: %s", type(error).__name__)

    def _handle(self, command: dict[str, Any]) -> None:
        request_id = self._validate(command)
        if request_id in self.last_commands:
            self._publish("commands/ack", self.last_commands[request_id], 1)
            return
        command_type = command["type"]
        payload = command["payload"]
        try:
            if command_type == "START_STREAM":
                self._start(command, payload)
            elif command_type == "EXTEND_STREAM":
                self.streams.extend(payload["streamId"], parse_time(payload["hardExpiresAt"]))
                self._ack(command, "SUCCEEDED", stream_id=payload["streamId"])
            elif command_type == "STOP_STREAM":
                self.streams.stop(payload["streamId"])
                self._stream_event(command, "STREAM_STOPPED", payload["streamId"])
                self.current_context = None
                self._ack(command, "SUCCEEDED", stream_id=payload["streamId"])
            elif command_type == "START_TALKBACK":
                self._start_talkback(command, payload)
            elif command_type == "STOP_TALKBACK":
                self.talkback.stop(payload["streamId"])
                self._ack(command, "SUCCEEDED", stream_id=payload["streamId"])
            elif command_type == "PING":
                self._ack(command, "SUCCEEDED")
            else:
                self._ack(command, "REJECTED", "UNSUPPORTED_COMMAND")
        except RuntimeError as error:
            code = str(error) if str(error) else "STREAM_COMMAND_FAILED"
            self._ack(command, "FAILED", code, payload.get("streamId"))

    def _start(self, command: dict[str, Any], payload: dict[str, Any]) -> None:
        stream_id = payload["streamId"]
        hard_expires_at = parse_time(payload["hardExpiresAt"])
        self._ack(command, "ACCEPTED", stream_id=stream_id, session_id=payload.get("sessionId"))
        created = self.streams.start(stream_id, hard_expires_at)
        self.current_context = command
        if created:
            self._stream_event(command, "STREAM_STARTING", stream_id)
            self.stop_event.wait(self.config.ready_delay_seconds)
        snapshot = self.streams.snapshot()
        if not snapshot.running:
            self._stream_event(command, "STREAM_ERROR", stream_id, "PUBLISH_FAILED")
            self._ack(command, "FAILED", "PUBLISH_FAILED", stream_id, payload.get("sessionId"))
            return
        self._stream_event(command, "STREAM_READY", stream_id)
        self._ack(command, "SUCCEEDED", stream_id=stream_id, session_id=payload.get("sessionId"))

    def _start_talkback(self, command: dict[str, Any], payload: dict[str, Any]) -> None:
        stream_id = payload["streamId"]
        hard_expires_at = parse_time(payload["hardExpiresAt"])
        self.talkback_retries = 0
        self.talkback.start(stream_id, hard_expires_at)
        # 재생 준비를 여기서 기다리지 않는다. 이 명령은 앱이 WHIP 송출을
        # 시작하기 전에 도착하므로, 이 시점에 플레이어가 살아 있는지는 스피커
        # 상태가 아니라 앱이 얼마나 빨리 붙었는지를 잴 뿐이다. 실제 재생 유지는
        # _monitor_talkback이 권한 만료까지 책임진다. 스피커가 아예 없으면
        # start()가 SPEAKER_UNAVAILABLE로 던져 위에서 FAILED로 처리된다.
        self._ack(command, "SUCCEEDED", stream_id=stream_id)

    def _validate(self, command: dict[str, Any]) -> str:
        if command.get("schemaVersion") != "2.0":
            raise ValueError("unsupported schema")
        if command.get("deviceId") != self.config.device_id:
            raise ValueError("wrong device")
        request_id = str(UUID(command["requestId"]))
        if parse_time(command["expiresAt"]) <= utc_now():
            self._ack(command, "EXPIRED", "COMMAND_EXPIRED")
            raise ValueError("expired command")
        if not isinstance(command.get("payload"), dict):
            raise ValueError("payload must be an object")
        return request_id

    def _monitor(self) -> None:
        while not self.stop_event.wait(1):
            self._monitor_talkback()
            snapshot = self.streams.snapshot()
            if snapshot.running and snapshot.hard_expires_at and utc_now() >= snapshot.hard_expires_at:
                context = self.current_context
                self.streams.stop(snapshot.stream_id)
                if context is not None and snapshot.stream_id is not None:
                    self._stream_event(context, "STREAM_HARD_EXPIRED", snapshot.stream_id, "EDGE_LEASE_EXPIRED")
                self.current_context = None
                continue
            finished = self.streams.clear_if_finished()
            if finished and finished.stream_id and self.current_context is not None:
                LOG.warning(
                    "스트림 릴레이 종료: stream=%s, return_code=%s",
                    finished.stream_id,
                    finished.return_code,
                )
                self._stream_event(
                    self.current_context,
                    "STREAM_ERROR",
                    finished.stream_id,
                    "STREAM_RELAY_EXITED",
                )
                self.current_context = None

    def _monitor_talkback(self) -> None:
        """발화 재생을 붙잡아 두고, 권한이 끝나면 스피커를 닫는다.

        STOP_TALKBACK이 유실돼도 hardExpiresAt에는 반드시 닫는다. 제어 경로가
        끊긴 채 재생이 남으면 집 안에서 소리가 계속 나온다.
        """
        snapshot = self.talkback.snapshot()
        if (
            snapshot.running
            and snapshot.hard_expires_at
            and utc_now() >= snapshot.hard_expires_at
        ):
            LOG.warning("발화 재생 강제 종료: stream=%s", snapshot.stream_id)
            self.talkback.stop(snapshot.stream_id)
            self.talkback_retries = 0
            return
        finished = self.talkback.clear_if_finished()
        if not finished or not finished.stream_id:
            return

        # 서버는 whipUrl을 앱에 돌려주기 전에 START_TALKBACK을 보낸다. 그래서
        # 기기가 앱보다 먼저 읽으러 가고, 아직 송출이 없는 경로라 플레이어가
        # 즉시 끝난다. 한 번 만에 포기하면 1~2초 뒤 시작된 발화를 아무도 듣지
        # 못한다. 권한이 살아있는 동안에는 다시 붙는다.
        if finished.hard_expires_at and utc_now() < finished.hard_expires_at:
            self.talkback_retries += 1
            if self.talkback_retries == 1:
                LOG.info("발화 송출 대기 중: stream=%s", finished.stream_id)
            try:
                self.talkback.start(finished.stream_id, finished.hard_expires_at)
                return
            except RuntimeError as error:
                LOG.warning("발화 재생 재시도 실패: %s", error)

        LOG.warning(
            "발화 재생 종료: stream=%s, return_code=%s, 재시도=%s",
            finished.stream_id,
            finished.return_code,
            self.talkback_retries,
        )
        self.talkback_retries = 0

    def _heartbeat_loop(self) -> None:
        while not self.stop_event.wait(30):
            snapshot = self.streams.snapshot()
            self._publish("heartbeat", {
                "schemaVersion": "2.0",
                "deviceId": self.config.device_id,
                "sentAt": isoformat(),
                "uptimeSeconds": int(time.monotonic()),
                "recording": False,
                "uploadQueueDepth": 0,
                "clockUnsynced": False,
                "firmwareVersion": self.config.firmware_version,
                "nodes": [{"nodeId": self.config.node_id, "online": True}],
                "streaming": snapshot.running,
            }, 0)

    def _status(self, state: str, reason: str) -> dict[str, Any]:
        return {
            "schemaVersion": "2.0",
            "deviceId": self.config.device_id,
            "state": state,
            "reason": reason,
            "firmwareVersion": self.config.firmware_version,
            "occurredAt": isoformat(),
        }

    def _ack(
        self,
        command: dict[str, Any],
        status: str,
        error_code: str | None = None,
        stream_id: str | None = None,
        session_id: str | None = None,
    ) -> None:
        ack = {
            "schemaVersion": "2.0",
            "requestId": command["requestId"],
            "deviceId": self.config.device_id,
            "status": status,
            "errorCode": error_code,
            "message": None,
            "occurredAt": isoformat(),
        }
        if stream_id:
            ack["streamId"] = stream_id
        if session_id:
            ack["sessionId"] = session_id
        self.last_commands[command["requestId"]] = ack
        self.last_commands.move_to_end(command["requestId"])
        while len(self.last_commands) > 200:
            self.last_commands.popitem(last=False)
        self._publish("commands/ack", ack, 1)

    def _stream_event(
        self,
        command: dict[str, Any],
        event_type: str,
        stream_id: str,
        error_code: str | None = None,
    ) -> None:
        payload = command.get("payload", {})
        event = {
            "schemaVersion": "2.0",
            "eventId": str(uuid4()),
            "requestId": command["requestId"],
            "deviceId": self.config.device_id,
            "streamId": stream_id,
            "type": event_type,
            "occurredAt": isoformat(),
            "hardExpiresAt": payload.get("hardExpiresAt") or isoformat(),
            "errorCode": error_code,
        }
        if payload.get("sessionId"):
            event["sessionId"] = payload["sessionId"]
        self._publish("stream/events", event, 1)

    def _publish(self, suffix: str, payload: dict[str, Any], qos: int, retain: bool = False) -> None:
        result = self.client.publish(
            f"{self.config.topic_base}/{suffix}",
            json.dumps(payload, separators=(",", ":")),
            qos=qos,
            retain=retain,
        )
        if result.rc != mqtt.MQTT_ERR_SUCCESS:
            LOG.warning("MQTT 발행 실패: topic=%s, rc=%s", suffix, result.rc)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    config = AgentConfig.from_environment()
    agent = DeviceAgent(config)
    signal.signal(signal.SIGTERM, lambda *_: agent.shutdown())
    signal.signal(signal.SIGINT, lambda *_: agent.shutdown())
    agent.run()
