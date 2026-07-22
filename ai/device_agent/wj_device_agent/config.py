from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
from uuid import UUID


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def _positive_int(name: str, default: int) -> int:
    value = int(os.environ.get(name, str(default)))
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


def _json_args(name: str) -> tuple[str, ...] | None:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return None
    value = json.loads(raw)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{name} must be a JSON string array")
    return tuple(value)


@dataclass(frozen=True)
class AgentConfig:
    device_id: str
    bearer_token: str
    firmware_version: str
    node_id: str
    mqtt_host: str
    mqtt_port: int
    mqtt_environment: str
    mqtt_ca_cert: Path
    publish_url_template: str
    ffmpeg_path: str
    ffmpeg_input_args: tuple[str, ...]
    ffmpeg_video_args: tuple[str, ...]
    ready_delay_seconds: int

    @property
    def topic_base(self) -> str:
        return f"{self.mqtt_environment}/wj/v1/devices/{self.device_id}"

    @classmethod
    def from_environment(cls) -> "AgentConfig":
        device_id = _required("DEVICE_ID")
        UUID(device_id)
        token = _required("DEVICE_BEARER_TOKEN")
        template = _required("MEDIA_PUBLISH_URL_TEMPLATE")
        if template.count("{stream_id}") != 1:
            raise ValueError("MEDIA_PUBLISH_URL_TEMPLATE must contain {stream_id} exactly once")
        if not template.startswith(("rtsp://", "rtsps://")):
            raise ValueError("MEDIA_PUBLISH_URL_TEMPLATE must use RTSP or RTSPS")

        fps = _positive_int("CAMERA_FPS", 30)
        width = _positive_int("CAMERA_WIDTH", 1280)
        height = _positive_int("CAMERA_HEIGHT", 720)
        input_args = _json_args("FFMPEG_INPUT_ARGS") or (
            "-f", "v4l2",
            "-input_format", os.environ.get("CAMERA_INPUT_FORMAT", "mjpeg"),
            "-framerate", str(fps),
            "-video_size", f"{width}x{height}",
            "-i", os.environ.get("CAMERA_DEVICE", "/dev/video0"),
        )
        video_args = _json_args("FFMPEG_VIDEO_ARGS") or (
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-tune", "zerolatency",
            "-pix_fmt", "yuv420p",
            "-g", str(fps * 2),
            "-bf", "0",
            "-b:v", os.environ.get("VIDEO_BITRATE", "2500k"),
        )
        ca_cert = Path(_required("MQTT_CA_CERT"))
        if not ca_cert.is_file():
            raise ValueError(f"MQTT_CA_CERT does not exist: {ca_cert}")
        return cls(
            device_id=device_id,
            bearer_token=token,
            firmware_version=os.environ.get("FIRMWARE_VERSION", "0.1.0"),
            node_id=os.environ.get("NODE_ID", "pi-gateway"),
            mqtt_host=_required("MQTT_HOST"),
            mqtt_port=_positive_int("MQTT_PORT", 8883),
            mqtt_environment=os.environ.get("MQTT_ENV", "prod"),
            mqtt_ca_cert=ca_cert,
            publish_url_template=template,
            ffmpeg_path=os.environ.get("FFMPEG_PATH", "/usr/bin/ffmpeg"),
            ffmpeg_input_args=input_args,
            ffmpeg_video_args=video_args,
            ready_delay_seconds=_positive_int("READY_DELAY_SECONDS", 3),
        )
