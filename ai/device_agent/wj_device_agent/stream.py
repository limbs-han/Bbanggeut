from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import subprocess
from threading import RLock
from typing import Callable
from uuid import UUID

from .config import AgentConfig


@dataclass(frozen=True)
class StreamSnapshot:
    stream_id: str | None
    running: bool
    hard_expires_at: datetime | None
    return_code: int | None


class StreamManager:
    def __init__(
        self,
        config: AgentConfig,
        process_factory: Callable[..., subprocess.Popen] = subprocess.Popen,
    ) -> None:
        self._config = config
        self._process_factory = process_factory
        self._lock = RLock()
        self._process: subprocess.Popen | None = None
        self._stream_id: str | None = None
        self._hard_expires_at: datetime | None = None

    def start(self, stream_id: str, hard_expires_at: datetime) -> bool:
        UUID(stream_id)
        with self._lock:
            self._clear_finished_locked()
            if self._process is not None:
                if self._stream_id == stream_id:
                    self._hard_expires_at = hard_expires_at
                    return False
                raise RuntimeError("DEVICE_BUSY")

            publish_url = self._config.publish_url_template.format(stream_id=stream_id)
            command = [
                self._config.ffmpeg_path,
                "-hide_banner", "-nostdin", "-loglevel", "warning",
                *self._config.ffmpeg_input_args,
                *self._config.ffmpeg_audio_input_args,
                "-map", "0:v:0",
                *(
                    ["-map", "0:a:0"]
                    if self._config.ffmpeg_audio_from_primary_input
                    else (["-map", "1:a:0"] if self._config.ffmpeg_audio_input_args else [])
                ),
                *self._config.ffmpeg_video_args,
                *(
                    self._config.ffmpeg_audio_args
                    if (
                        self._config.ffmpeg_audio_from_primary_input
                        or self._config.ffmpeg_audio_input_args
                    )
                    else ("-an",)
                ),
                *self._config.ffmpeg_output_args,
                "-f", "rtsp", "-rtsp_transport", "tcp", publish_url,
            ]
            self._process = self._process_factory(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                # stderr 는 버리지 않는다. 버리면 송출이 실패했을 때 저널에
                # 남는 것이 return_code 숫자 하나뿐이라 원인을 알 방법이 없다.
                # 상속시키면 ffmpeg 의 오류가 그대로 유닛 저널에 들어간다.
                stderr=None,
            )
            self._stream_id = stream_id
            self._hard_expires_at = hard_expires_at
            return True

    def extend(self, stream_id: str, hard_expires_at: datetime) -> None:
        with self._lock:
            self._clear_finished_locked()
            if self._process is None or self._stream_id != stream_id:
                raise RuntimeError("STREAM_NOT_RUNNING")
            self._hard_expires_at = hard_expires_at

    def stop(self, stream_id: str | None = None) -> bool:
        with self._lock:
            process = self._process
            if process is None:
                return False
            if stream_id is not None and stream_id != self._stream_id:
                raise RuntimeError("STREAM_NOT_RUNNING")
            self._process = None
            self._stream_id = None
            self._hard_expires_at = None

        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        return True

    def snapshot(self) -> StreamSnapshot:
        with self._lock:
            return_code = self._process.poll() if self._process is not None else None
            return StreamSnapshot(
                self._stream_id,
                self._process is not None and return_code is None,
                self._hard_expires_at,
                return_code,
            )

    def clear_if_finished(self) -> StreamSnapshot | None:
        with self._lock:
            if self._process is None:
                return None
            return_code = self._process.poll()
            if return_code is None:
                return None
            previous = StreamSnapshot(
                self._stream_id, False, self._hard_expires_at, return_code
            )
            self._process = None
            self._stream_id = None
            self._hard_expires_at = None
            return previous

    def _clear_finished_locked(self) -> None:
        if self._process is not None and self._process.poll() is not None:
            self._process = None
            self._stream_id = None
            self._hard_expires_at = None
