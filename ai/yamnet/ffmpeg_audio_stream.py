"""Reconnect an FFmpeg-decoded network audio stream with bounded backoff."""

from __future__ import annotations

import re
import subprocess
import threading
from collections.abc import Callable, Sequence
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit


SENSITIVE_QUERY_KEYS = {
    "access_token",
    "api_key",
    "auth",
    "key",
    "pass",
    "password",
    "signature",
    "token",
}

RTSP_TIMEOUT_OPTIONS = ("rw_timeout", "stimeout", "timeout")


def redact_stream_url(value: str) -> str:
    """Remove URL credentials before a stream address is written to logs."""

    try:
        parsed = urlsplit(value)
    except ValueError:
        return "<invalid-stream-url>"
    if not parsed.scheme:
        return value

    netloc = parsed.netloc
    if "@" in netloc:
        host = netloc.rsplit("@", 1)[1]
        netloc = f"***:***@{host}"
    query = urlencode(
        [
            (
                key,
                "***" if key.casefold() in SENSITIVE_QUERY_KEYS else query_value,
            )
            for key, query_value in parse_qsl(parsed.query, keep_blank_values=True)
        ],
        safe="*",
    )
    return urlunsplit((parsed.scheme, netloc, parsed.path, query, ""))


def detect_rtsp_timeout_option(
    ffmpeg_path: str,
    *,
    runner: Callable[..., Any] = subprocess.run,
) -> str | None:
    """Return the read-timeout option supported by this FFmpeg build.

    JetPack FFmpeg builds do not expose a consistent option name. Some use
    ``rw_timeout``, older builds use ``stimeout``, and newer RTSP demuxers can
    expose ``timeout``. Omitting an unsupported option is safer than making
    every audio connection exit before it reads its first packet.
    """

    detected: set[str] = set()
    for help_target in ("demuxer=rtsp", "protocol=tcp"):
        try:
            result = runner(
                [
                    ffmpeg_path,
                    "-hide_banner",
                    "-h",
                    help_target,
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue

        output = str(getattr(result, "stdout", "") or "")
        detected.update(
            re.findall(
                r"^\s+-(rw_timeout|stimeout|timeout)\b",
                output,
                flags=re.MULTILINE,
            )
        )

    for option in RTSP_TIMEOUT_OPTIONS:
        if option in detected:
            return option
    return None


def build_audio_command(
    ffmpeg_path: str,
    source: str,
    sample_rate: int,
    read_timeout_seconds: float,
    *,
    rtsp_timeout_option: str | None = None,
) -> list[str]:
    if (
        rtsp_timeout_option is not None
        and rtsp_timeout_option not in RTSP_TIMEOUT_OPTIONS
    ):
        raise ValueError(
            "rtsp_timeout_option must be rw_timeout, stimeout, timeout, or None"
        )

    command = [
        ffmpeg_path,
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "error",
        "-fflags",
        "nobuffer",
        "-flags",
        "low_delay",
    ]
    if source.casefold().startswith(("rtsp://", "rtsps://")):
        command.extend(
            [
                "-rtsp_transport",
                "tcp",
            ]
        )
        if rtsp_timeout_option is not None:
            command.extend(
                [
                    f"-{rtsp_timeout_option}",
                    str(max(1, round(read_timeout_seconds * 1_000_000))),
                ]
            )
    command.extend(
        [
            "-i",
            source,
            "-map",
            "0:a:0",
            "-vn",
            "-ac",
            "1",
            "-ar",
            str(sample_rate),
            "-f",
            "f32le",
            "pipe:1",
        ]
    )
    return command


class ReconnectingFfmpegAudio:
    """Read fixed-size PCM blocks and restart FFmpeg after source failures."""

    def __init__(
        self,
        command: Sequence[str],
        block_bytes: int,
        on_block: Callable[[bytes], None],
        *,
        reconnect_initial_seconds: float = 1.0,
        reconnect_max_seconds: float = 10.0,
        popen_factory: Callable[..., Any] = subprocess.Popen,
        log: Callable[[str], None] = print,
        safe_source: str = "stream",
    ) -> None:
        if block_bytes <= 0:
            raise ValueError("block_bytes must be positive")
        if reconnect_initial_seconds <= 0:
            raise ValueError("reconnect_initial_seconds must be positive")
        if reconnect_max_seconds < reconnect_initial_seconds:
            raise ValueError(
                "reconnect_max_seconds must be at least reconnect_initial_seconds"
            )

        self._command = list(command)
        self._block_bytes = block_bytes
        self._on_block = on_block
        self._reconnect_initial_seconds = reconnect_initial_seconds
        self._reconnect_max_seconds = reconnect_max_seconds
        self._popen_factory = popen_factory
        self._log = log
        self._safe_source = safe_source

        self._stop = threading.Event()
        self._process_lock = threading.Lock()
        self._process: Any | None = None
        self._connected_once = False
        self._reader = threading.Thread(
            target=self._reader_loop,
            name="reconnecting-ffmpeg-audio",
            daemon=True,
        )

    def start(self) -> None:
        self._reader.start()

    def _stop_process(self, process: Any) -> None:
        try:
            process.terminate()
            process.wait(timeout=3)
        except (subprocess.TimeoutExpired, ProcessLookupError):
            try:
                process.kill()
                process.wait(timeout=1)
            except Exception:
                pass
        except Exception:
            pass

    def _reader_loop(self) -> None:
        delay = self._reconnect_initial_seconds
        while not self._stop.is_set():
            process = None
            try:
                process = self._popen_factory(
                    self._command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
                if process.stdout is None:
                    raise RuntimeError("FFmpeg audio pipe was not created")
                with self._process_lock:
                    self._process = process

                buffered = bytearray()
                received_block = False
                while not self._stop.is_set():
                    data = process.stdout.read(self._block_bytes - len(buffered))
                    if not data:
                        raise RuntimeError(
                            f"FFmpeg stopped with status {process.poll()}"
                        )
                    buffered.extend(data)
                    if len(buffered) < self._block_bytes:
                        continue

                    if not received_block:
                        if self._connected_once:
                            self._log(f"Audio stream reconnected: {self._safe_source}")
                        else:
                            self._log(f"Audio stream connected: {self._safe_source}")
                            self._connected_once = True
                        received_block = True
                        delay = self._reconnect_initial_seconds

                    self._on_block(bytes(buffered))
                    buffered.clear()
            except Exception as exc:
                if not self._stop.is_set():
                    self._log(
                        f"Audio stream unavailable ({type(exc).__name__}); "
                        f"retrying in {delay:.1f}s: {self._safe_source}"
                    )
            finally:
                if process is not None:
                    self._stop_process(process)
                with self._process_lock:
                    if self._process is process:
                        self._process = None

            if self._stop.is_set() or self._stop.wait(delay):
                break
            delay = min(delay * 2.0, self._reconnect_max_seconds)

    def close(self) -> None:
        if self._stop.is_set():
            return
        self._stop.set()
        with self._process_lock:
            process = self._process
        if process is not None:
            self._stop_process(process)
        self._reader.join(timeout=4.0)
