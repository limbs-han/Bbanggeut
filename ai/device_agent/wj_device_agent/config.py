from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
from urllib.parse import urlsplit
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


def _boolean(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    value = raw.strip().lower()
    if value in {"1", "true", "yes", "on"}:
        return True
    if value in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be true or false")


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
    media_tls_ca_cert: Path | None
    ffmpeg_output_args: tuple[str, ...]
    ffmpeg_path: str
    ffmpeg_input_args: tuple[str, ...]
    ffmpeg_video_args: tuple[str, ...]
    ffmpeg_audio_input_args: tuple[str, ...]
    ffmpeg_audio_args: tuple[str, ...]
    ffmpeg_audio_from_primary_input: bool
    ready_delay_seconds: int
    # 스피커가 없는 기기에서는 비워 둔다. 그 경우 START_TALKBACK은
    # SPEAKER_UNAVAILABLE로 거절된다.
    talkback_url_template: str = ""
    talkback_command_template: tuple[str, ...] = ()

    @property
    def topic_base(self) -> str:
        return f"{self.mqtt_environment}/wj/v2/devices/{self.device_id}"

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
        media_tls_ca_cert: Path | None = None
        ffmpeg_output_args: tuple[str, ...] = ()
        if template.startswith("rtsps://"):
            parsed_template = urlsplit(template)
            if (
                not parsed_template.hostname
                or parsed_template.username is None
                or parsed_template.password is None
                or parsed_template.path != "/live/{stream_id}"
                or parsed_template.query
                or parsed_template.fragment
            ):
                raise ValueError(
                    "RTSPS MEDIA_PUBLISH_URL_TEMPLATE must include credentials "
                    "and use /live/{stream_id}"
                )
            media_tls_ca_cert = Path(_required("MEDIA_TLS_CA_CERT"))
            if not media_tls_ca_cert.is_file():
                raise ValueError(
                    f"MEDIA_TLS_CA_CERT does not exist: {media_tls_ca_cert}"
                )
            ffmpeg_output_args = (
                "-tls_verify", "1",
                "-ca_file", str(media_tls_ca_cert),
            )

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
        audio_input_args = _json_args("FFMPEG_AUDIO_INPUT_ARGS") or ()
        audio_args = _json_args("FFMPEG_AUDIO_ARGS") or ()
        audio_from_primary = _boolean("FFMPEG_AUDIO_FROM_PRIMARY_INPUT")
        if audio_from_primary and audio_input_args:
            raise ValueError(
                "FFMPEG_AUDIO_INPUT_ARGS must be empty when audio comes from the primary input"
            )
        if audio_from_primary and not audio_args:
            raise ValueError(
                "FFMPEG_AUDIO_ARGS is required when audio comes from the primary input"
            )
        if not audio_from_primary and bool(audio_input_args) != bool(audio_args):
            raise ValueError(
                "FFMPEG_AUDIO_INPUT_ARGS and FFMPEG_AUDIO_ARGS must be set together"
            )
        ca_cert = Path(_required("MQTT_CA_CERT"))
        if not ca_cert.is_file():
            raise ValueError(f"MQTT_CA_CERT does not exist: {ca_cert}")

        ffmpeg_path = os.environ.get("FFMPEG_PATH", "/usr/bin/ffmpeg")
        talkback_url_template = os.environ.get("MEDIA_TALKBACK_URL_TEMPLATE", "").strip()
        if not talkback_url_template and _boolean("TALKBACK_ENABLED"):
            # 발화 경로는 같은 MediaMTX의 형제 경로다. 기기 계정에는 이 경로의
            # read 권한만 있으므로 송출 자격 증명을 그대로 재사용한다.
            talkback_url_template = template.replace(
                "/live/{stream_id}", "/talkback/{stream_id}"
            )
            if "/talkback/{stream_id}" not in talkback_url_template:
                raise ValueError(
                    "MEDIA_TALKBACK_URL_TEMPLATE is required when "
                    "MEDIA_PUBLISH_URL_TEMPLATE does not use /live/{stream_id}"
                )
        if talkback_url_template:
            if talkback_url_template.count("{stream_id}") != 1:
                raise ValueError(
                    "MEDIA_TALKBACK_URL_TEMPLATE must contain {stream_id} exactly once"
                )
            if not talkback_url_template.startswith(("rtsp://", "rtsps://")):
                raise ValueError("MEDIA_TALKBACK_URL_TEMPLATE must use RTSP or RTSPS")

        talkback_command = _json_args("TALKBACK_COMMAND")
        if talkback_command is None and talkback_url_template:
            tls_args: tuple[str, ...] = ()
            if talkback_url_template.startswith("rtsps://"):
                if media_tls_ca_cert is None:
                    media_tls_ca_cert = Path(_required("MEDIA_TLS_CA_CERT"))
                    if not media_tls_ca_cert.is_file():
                        raise ValueError(
                            f"MEDIA_TLS_CA_CERT does not exist: {media_tls_ca_cert}"
                        )
                tls_args = ("-tls_verify", "1", "-ca_file", str(media_tls_ca_cert))
            talkback_command = (
                ffmpeg_path,
                "-hide_banner", "-nostdin", "-loglevel", "warning",
                *tls_args,
                "-rtsp_transport", "tcp",
                "-i", "{url}",
                "-f", os.environ.get("TALKBACK_OUTPUT_FORMAT", "alsa"),
                os.environ.get("TALKBACK_OUTPUT_DEVICE", "default"),
            )
        if talkback_command is not None and talkback_command.count("{url}") != 1:
            raise ValueError("TALKBACK_COMMAND must contain {url} exactly once")

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
            media_tls_ca_cert=media_tls_ca_cert,
            ffmpeg_output_args=ffmpeg_output_args,
            ffmpeg_path=ffmpeg_path,
            ffmpeg_input_args=input_args,
            ffmpeg_video_args=video_args,
            ffmpeg_audio_input_args=audio_input_args,
            ffmpeg_audio_args=audio_args,
            ffmpeg_audio_from_primary_input=audio_from_primary,
            ready_delay_seconds=_positive_int("READY_DELAY_SECONDS", 3),
            talkback_url_template=talkback_url_template,
            talkback_command_template=talkback_command or (),
        )
