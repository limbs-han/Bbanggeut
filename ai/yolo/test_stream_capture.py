"""Tests for low-latency stream capture and automatic reconnection."""

from __future__ import annotations

import threading
import unittest

from stream_capture import LatestFrameCapture, redact_stream_url


class FakeCapture:
    def __init__(
        self,
        frames: list[object],
        *,
        opened: bool = True,
        properties: dict[int, float] | None = None,
    ) -> None:
        self.frames = list(frames)
        self.opened = opened
        self.properties = properties or {}
        self.frames_read = threading.Event()
        self.released = threading.Event()

    def isOpened(self) -> bool:  # noqa: N802 - OpenCV-compatible fake.
        return self.opened

    def read(self) -> tuple[bool, object | None]:
        if self.frames:
            frame = self.frames.pop(0)
            if not self.frames:
                self.frames_read.set()
            return True, frame
        self.released.wait(timeout=1.0)
        return False, None

    def get(self, property_id: int) -> float:
        return self.properties.get(property_id, 0.0)

    def release(self) -> None:
        self.released.set()


class LatestFrameCaptureTests(unittest.TestCase):
    def test_slow_consumer_receives_only_latest_frame(self) -> None:
        underlying = FakeCapture([1, 2, 3], properties={10: 720.0})
        capture = LatestFrameCapture(
            "rtsp://camera/live",
            lambda source: underlying,
            property_ids=(10,),
            reconnect_initial_seconds=0.01,
            reconnect_max_seconds=0.02,
            log=lambda message: None,
        )
        self.addCleanup(capture.release)

        self.assertTrue(underlying.frames_read.wait(timeout=1.0))
        ok, frame = capture.read()

        self.assertTrue(ok)
        self.assertEqual(frame, 3)
        self.assertEqual(capture.get(10), 720.0)

    def test_failed_open_is_retried(self) -> None:
        failed = FakeCapture([], opened=False)
        recovered = FakeCapture([42])
        calls: list[str] = []

        def factory(source: str) -> FakeCapture:
            calls.append(source)
            return failed if len(calls) == 1 else recovered

        capture = LatestFrameCapture(
            "udp://127.0.0.1:23000",
            factory,
            reconnect_initial_seconds=0.01,
            reconnect_max_seconds=0.02,
            log=lambda message: None,
        )
        self.addCleanup(capture.release)

        ok, frame = capture.read()

        self.assertTrue(ok)
        self.assertEqual(frame, 42)
        self.assertGreaterEqual(len(calls), 2)

    def test_credentials_are_redacted(self) -> None:
        self.assertEqual(
            redact_stream_url("rtsp://alice:secret@example.test:8554/homecam/ai"),
            "rtsp://***:***@example.test:8554/homecam/ai",
        )
        self.assertEqual(
            redact_stream_url("udp://127.0.0.1:23000"),
            "udp://127.0.0.1:23000",
        )
        self.assertEqual(
            redact_stream_url("rtsp://camera/live?token=secret&profile=ai"),
            "rtsp://camera/live?token=***&profile=ai",
        )


if __name__ == "__main__":
    unittest.main()
