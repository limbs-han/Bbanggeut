from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import subprocess
from threading import RLock
from typing import Callable
from uuid import UUID

from .config import AgentConfig


@dataclass(frozen=True)
class TalkbackSnapshot:
    stream_id: str | None
    running: bool
    hard_expires_at: datetime | None
    return_code: int | None


class TalkbackManager:
    """앱이 보내는 역방향 오디오를 읽어 기기 스피커로 재생한다.

    라이브 송출을 담당하는 StreamManager와 완전히 분리된 프로세스를 쓴다.
    발화 때문에 송출 ffmpeg를 재시작하면 말할 때마다 영상이 끊기기 때문이다.
    """

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
        if not self._config.talkback_command_template:
            raise RuntimeError("SPEAKER_UNAVAILABLE")
        with self._lock:
            self._clear_finished_locked()
            if self._process is not None:
                # 서버는 시청자 heartbeat 주기마다 START_TALKBACK을 다시 보낸다.
                # 같은 발화면 만료 시각만 밀고 재생을 끊지 않는다.
                if self._stream_id == stream_id:
                    self._hard_expires_at = hard_expires_at
                    return False
                raise RuntimeError("DEVICE_BUSY")

            read_url = self._config.talkback_url_template.format(stream_id=stream_id)
            command = [
                read_url if part == "{url}" else part
                for part in self._config.talkback_command_template
            ]
            self._process = self._process_factory(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                # Keep FFmpeg diagnostics attached to the systemd service.
                # Talkback can fail before a long-lived process is visible in
                # pgrep (RTSP path, TLS, authentication, or ALSA errors), and
                # discarding stderr makes all of those failures indistinguishable.
                stderr=None,
            )
            self._stream_id = stream_id
            self._hard_expires_at = hard_expires_at
            return True

    def stop(self, stream_id: str | None = None) -> bool:
        with self._lock:
            process = self._process
            if process is None:
                return False
            if stream_id is not None and stream_id != self._stream_id:
                raise RuntimeError("TALKBACK_NOT_RUNNING")
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

    def snapshot(self) -> TalkbackSnapshot:
        with self._lock:
            return_code = self._process.poll() if self._process is not None else None
            return TalkbackSnapshot(
                self._stream_id,
                self._process is not None and return_code is None,
                self._hard_expires_at,
                return_code,
            )

    def clear_if_finished(self) -> TalkbackSnapshot | None:
        with self._lock:
            if self._process is None:
                return None
            return_code = self._process.poll()
            if return_code is None:
                return None
            previous = TalkbackSnapshot(
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
