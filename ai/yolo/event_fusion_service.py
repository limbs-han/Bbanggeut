"""Enrich YAMNet laughter events with the latest YOLO vision context."""

from __future__ import annotations

import argparse
import json
import os
import time
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def validate_laughter_event(payload: dict[str, Any]) -> None:
    required = {
        "schema_version",
        "event_id",
        "device_id",
        "event_type",
        "detected_at",
        "score",
        "clip",
    }
    missing = sorted(required.difference(payload))
    if missing:
        raise ValueError(f"missing required fields: {', '.join(missing)}")
    try:
        UUID(str(payload["event_id"]))
    except ValueError as exc:
        raise ValueError("event_id must be a UUID") from exc
    if not str(payload["device_id"]).strip():
        raise ValueError("device_id cannot be empty")
    if str(payload["event_type"]).casefold() != "laughter":
        raise ValueError("event_type must be laughter")

    detected_at = datetime.fromisoformat(
        str(payload["detected_at"]).replace("Z", "+00:00")
    )
    if detected_at.tzinfo is None or detected_at.utcoffset() != timedelta(0):
        raise ValueError("detected_at must be UTC ISO-8601")

    score = payload["score"]
    if isinstance(score, bool) or not isinstance(score, (int, float)):
        raise ValueError("score must be a number")
    if not 0.0 <= float(score) <= 1.0:
        raise ValueError("score must be between 0 and 1")

    clip = payload["clip"]
    if not isinstance(clip, dict):
        raise ValueError("clip must be an object")
    for field in ("pre_seconds", "post_seconds"):
        value = clip.get(field)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"clip.{field} must be a number")
        if float(value) <= 0:
            raise ValueError(f"clip.{field} must be positive")


def build_fused_event(
    laughter_event: dict[str, Any],
    vision_state: dict[str, Any] | None,
    vision_age_ms: int | None,
    max_vision_age_ms: int,
) -> dict[str, Any]:
    fused = dict(laughter_event)
    source_schema_version = fused.get("schema_version")
    fused["schema_version"] = "1.1"
    fused["event_type"] = str(fused.get("event_type", "laughter")).casefold()
    if source_schema_version is not None:
        fused["source_schema_version"] = source_schema_version
    fused["fused_at"] = utc_now()

    context_available = (
        vision_state is not None
        and vision_age_ms is not None
        and 0 <= vision_age_ms <= max_vision_age_ms
    )
    if not context_available:
        fused["vision_context"] = {
            "available": False,
            "age_ms": vision_age_ms,
            "object_count": 0,
            "track_ids": [],
        }
        return fused

    assert vision_state is not None
    counts = vision_state.get("object_counts") or {}
    fused["vision_context"] = {
        "available": True,
        "age_ms": vision_age_ms,
        "object_count": int(vision_state.get("total_stable_objects", 0)),
        "track_ids": list(
            vision_state.get("track_ids")
            or vision_state.get("target_ids")
            or []
        ),
        "person_count": int(counts.get("person", 0)),
        "cat_count": int(counts.get("cat", 0)),
        "dog_count": int(counts.get("dog", 0)),
        "target_ids": list(vision_state.get("target_ids") or []),
        "target_count": int(vision_state.get("target_count", 0)),
        "total_stable_objects": int(
            vision_state.get("total_stable_objects", 0)
        ),
        "camera_state": vision_state.get("state", "UNKNOWN"),
        "camera_direction": vision_state.get("direction", "UNKNOWN"),
        "error_x": vision_state.get("error_x"),
        "error_y": vision_state.get("error_y"),
        "limited_group": bool(vision_state.get("limited_group", False)),
    }
    return fused


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fuse YAMNet laughter events with the latest YOLO state."
    )
    parser.add_argument("--mqtt-host", default=os.getenv("MQTT_HOST", "localhost"))
    parser.add_argument(
        "--mqtt-port", type=int, default=int(os.getenv("MQTT_PORT", "1883"))
    )
    parser.add_argument("--mqtt-username", default=os.getenv("MQTT_USERNAME"))
    parser.add_argument("--mqtt-password", default=os.getenv("MQTT_PASSWORD"))
    parser.add_argument("--device-id", default=os.getenv("DEVICE_ID", "homecam-001"))
    parser.add_argument("--vision-topic")
    parser.add_argument("--laughter-topic")
    parser.add_argument("--output-topic")
    parser.add_argument(
        "--max-vision-age-ms",
        type=int,
        default=2_000,
        help="Attach vision context only when its last message is this recent.",
    )
    args = parser.parse_args()
    if not 1 <= args.mqtt_port <= 65_535:
        parser.error("--mqtt-port must be between 1 and 65535")
    if args.max_vision_age_ms < 0:
        parser.error("--max-vision-age-ms cannot be negative")
    if not args.device_id.strip():
        parser.error("--device-id cannot be empty")
    return args


class EventFusionService:
    def __init__(self, args: argparse.Namespace) -> None:
        try:
            import paho.mqtt.client as mqtt
        except ImportError as exc:
            raise SystemExit(
                "MQTT package is missing. Install requirements-autoframe-jetson.txt."
            ) from exc

        self.mqtt = mqtt
        self.args = args
        self.vision_topic = args.vision_topic or (
            f"homecam/v1/{args.device_id}/ai/vision/state"
        )
        self.laughter_topic = args.laughter_topic or (
            f"homecam/v1/{args.device_id}/ai/laughter/detected"
        )
        self.output_topic = args.output_topic or (
            f"homecam/v1/{args.device_id}/events/memory-candidate"
        )
        self.latest_vision: dict[str, Any] | None = None
        self.latest_vision_received_at: float | None = None
        self.client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"{args.device_id}-event-fusion",
            protocol=mqtt.MQTTv311,
        )
        if args.mqtt_username:
            self.client.username_pw_set(args.mqtt_username, args.mqtt_password)
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message

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
            print(f"MQTT connection failed: {reason_code}")
            return
        client.subscribe([(self.vision_topic, 0), (self.laughter_topic, 1)])
        print(f"Vision input: {self.vision_topic}")
        print(f"Laughter input: {self.laughter_topic}")
        print(f"Fused output: {self.output_topic}")

    def _on_message(self, client: Any, userdata: Any, message: Any) -> None:
        del userdata
        try:
            payload = json.loads(message.payload.decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("payload is not a JSON object")
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            print(f"Ignored invalid MQTT payload on {message.topic}: {exc}")
            return

        if message.topic == self.vision_topic:
            self.latest_vision = payload
            self.latest_vision_received_at = time.monotonic()
            return
        if message.topic != self.laughter_topic:
            return
        try:
            validate_laughter_event(payload)
        except (TypeError, ValueError) as exc:
            print(f"Ignored invalid laughter event: {exc}")
            return

        now = time.monotonic()
        age_ms = (
            None
            if self.latest_vision_received_at is None
            else max(0, round((now - self.latest_vision_received_at) * 1000.0))
        )
        fused = build_fused_event(
            payload,
            self.latest_vision,
            age_ms,
            self.args.max_vision_age_ms,
        )
        published = client.publish(
            self.output_topic,
            payload=json.dumps(fused, ensure_ascii=False, separators=(",", ":")),
            qos=1,
            retain=False,
        )
        if published.rc != self.mqtt.MQTT_ERR_SUCCESS:
            print(f"Failed to publish fused event: rc={published.rc}")
            return
        context = fused["vision_context"]
        print(
            f"Fused laughter event: event_id={fused.get('event_id', 'unknown')} "
            f"vision_available={context['available']} age_ms={context['age_ms']}"
        )

    def run(self) -> None:
        try:
            self.client.connect(self.args.mqtt_host, self.args.mqtt_port, keepalive=60)
            print(f"MQTT broker: {self.args.mqtt_host}:{self.args.mqtt_port}")
            self.client.loop_forever(retry_first_connection=True)
        except KeyboardInterrupt:
            print("\nEvent fusion stopped by user.")
        finally:
            self.client.disconnect()


def main() -> None:
    EventFusionService(parse_args()).run()


if __name__ == "__main__":
    main()
