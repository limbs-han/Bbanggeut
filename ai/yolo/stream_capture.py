"""Low-latency reconnecting capture helpers for network video streams."""

from __future__ import annotations

import threading
from collections.abc import Callable, Iterable
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


class LatestFrameCapture:
    """Continuously read a stream and expose only its newest decoded frame.

    The background reader owns the underlying capture object. When the source
    fails, it releases that object and recreates it with exponential backoff.
    A slow inference consumer therefore cannot build up an unbounded frame
    queue.
    """

    def __init__(
        self,
        source: str,
        capture_factory: Callable[[str], Any],
        *,
        property_ids: Iterable[int] = (),
        reconnect_initial_seconds: float = 1.0,
        reconnect_max_seconds: float = 10.0,
        log: Callable[[str], None] = print,
    ) -> None:
        if reconnect_initial_seconds <= 0:
            raise ValueError("reconnect_initial_seconds must be positive")
        if reconnect_max_seconds < reconnect_initial_seconds:
            raise ValueError(
                "reconnect_max_seconds must be at least reconnect_initial_seconds"
            )

        self.source = source
        self._capture_factory = capture_factory
        self._property_ids = tuple(property_ids)
        self._reconnect_initial_seconds = reconnect_initial_seconds
        self._reconnect_max_seconds = reconnect_max_seconds
        self._log = log

        self._condition = threading.Condition()
        self._stop = threading.Event()
        self._latest_frame: Any | None = None
        self._frame_sequence = 0
        self._delivered_sequence = 0
        self._properties: dict[int, float] = {}
        self._active_capture: Any | None = None
        self._connected_once = False
        self._reader = threading.Thread(
            target=self._reader_loop,
            name="latest-video-frame-reader",
            daemon=True,
        )
        self._reader.start()

    def _wait_before_retry(self, delay: float) -> bool:
        return self._stop.wait(delay)

    def _release_capture(self, capture: Any) -> None:
        try:
            capture.release()
        except Exception:
            pass
        with self._condition:
            if self._active_capture is capture:
                self._active_capture = None

    def _reader_loop(self) -> None:
        delay = self._reconnect_initial_seconds
        safe_source = redact_stream_url(self.source)

        while not self._stop.is_set():
            capture = None
            try:
                capture = self._capture_factory(self.source)
                if capture is None or not capture.isOpened():
                    raise RuntimeError("capture did not open")

                with self._condition:
                    self._active_capture = capture
                    self._properties = {
                        property_id: float(capture.get(property_id))
                        for property_id in self._property_ids
                    }

                if self._connected_once:
                    self._log(f"Video stream reconnected: {safe_source}")
                else:
                    self._log(f"Video stream connected: {safe_source}")
                    self._connected_once = True
                delay = self._reconnect_initial_seconds

                while not self._stop.is_set():
                    ok, frame = capture.read()
                    if not ok or frame is None:
                        raise RuntimeError("frame read failed")
                    with self._condition:
                        self._latest_frame = frame
                        self._frame_sequence += 1
                        self._condition.notify_all()
            except Exception as exc:
                if not self._stop.is_set():
                    self._log(
                        f"Video stream unavailable ({type(exc).__name__}); "
                        f"retrying in {delay:.1f}s: {safe_source}"
                    )
            finally:
                if capture is not None:
                    self._release_capture(capture)

            if self._stop.is_set() or self._wait_before_retry(delay):
                break
            delay = min(delay * 2.0, self._reconnect_max_seconds)

        with self._condition:
            self._condition.notify_all()

    def read(self) -> tuple[bool, Any | None]:
        with self._condition:
            while (
                not self._stop.is_set()
                and self._frame_sequence <= self._delivered_sequence
            ):
                self._condition.wait(timeout=0.5)
            if self._stop.is_set():
                return False, None

            self._delivered_sequence = self._frame_sequence
            return True, self._latest_frame

    def get(self, property_id: int) -> float:
        with self._condition:
            return self._properties.get(property_id, 0.0)

    def isOpened(self) -> bool:  # noqa: N802 - matches OpenCV's capture API.
        return not self._stop.is_set()

    def set(self, property_id: int, value: float) -> bool:
        del property_id, value
        return False

    def release(self) -> None:
        if self._stop.is_set():
            return
        self._stop.set()
        with self._condition:
            capture = self._active_capture
            self._condition.notify_all()
        if capture is not None:
            self._release_capture(capture)
        self._reader.join(timeout=3.0)
