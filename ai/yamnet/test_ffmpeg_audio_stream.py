"""Tests for FFmpeg network-audio reconnection."""

from __future__ import annotations

import io
import threading
import unittest

from ffmpeg_audio_stream import (
    ReconnectingFfmpegAudio,
    build_audio_command,
    detect_rtsp_timeout_option,
    redact_stream_url,
)


class FakeProcess:
    def __init__(self, payload: bytes) -> None:
        self.stdout = io.BytesIO(payload)
        self.stopped = False

    def poll(self) -> int:
        return 0

    def terminate(self) -> None:
        self.stopped = True

    def kill(self) -> None:
        self.stopped = True

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        return 0


class FfmpegAudioStreamTests(unittest.TestCase):
    def test_rtsp_command_decodes_only_16khz_mono_audio(self) -> None:
        command = build_audio_command(
            "/usr/bin/ffmpeg",
            "rtsp://camera/homecam/ai",
            16_000,
            5.0,
        )

        self.assertIn("-rtsp_transport", command)
        self.assertNotIn("-rw_timeout", command)
        self.assertEqual(command[command.index("-ac") + 1], "1")
        self.assertEqual(command[command.index("-ar") + 1], "16000")
        self.assertEqual(command[-2:], ["f32le", "pipe:1"])

    def test_rtsp_command_uses_detected_timeout_option(self) -> None:
        command = build_audio_command(
            "/usr/bin/ffmpeg",
            "rtsp://camera/homecam/ai",
            16_000,
            5.0,
            rtsp_timeout_option="stimeout",
        )

        self.assertEqual(command[command.index("-stimeout") + 1], "5000000")

    def test_detects_jetpack_stimeout_option(self) -> None:
        class Result:
            stdout = """
  -rtsp_transport    <flags>      .D......... set RTSP transport protocols
  -stimeout           <int64>     .D......... set socket I/O timeout
"""

        def runner(command: list[str], **kwargs: object) -> Result:
            del command, kwargs
            return Result()

        self.assertEqual(
            detect_rtsp_timeout_option("/usr/bin/ffmpeg", runner=runner),
            "stimeout",
        )

    def test_omits_timeout_when_ffmpeg_exposes_no_supported_option(self) -> None:
        class Result:
            stdout = "RTSP demuxer AVOptions:\n  -rtsp_transport <flags>"

        def runner(command: list[str], **kwargs: object) -> Result:
            del command, kwargs
            return Result()

        self.assertIsNone(
            detect_rtsp_timeout_option("/usr/bin/ffmpeg", runner=runner)
        )

    def test_stream_reconnects_after_eof(self) -> None:
        payloads = [b"abcd", b"efgh"]
        factory_calls = 0
        received: list[bytes] = []
        complete = threading.Event()

        def factory(command: list[str], **kwargs: object) -> FakeProcess:
            nonlocal factory_calls
            del command, kwargs
            index = min(factory_calls, len(payloads) - 1)
            factory_calls += 1
            return FakeProcess(payloads[index])

        def on_block(block: bytes) -> None:
            received.append(block)
            if len(received) >= 2:
                complete.set()

        stream = ReconnectingFfmpegAudio(
            ["ffmpeg"],
            4,
            on_block,
            reconnect_initial_seconds=0.01,
            reconnect_max_seconds=0.02,
            popen_factory=factory,
            log=lambda message: None,
        )
        stream.start()
        self.addCleanup(stream.close)

        self.assertTrue(complete.wait(timeout=1.0))
        self.assertEqual(received[:2], payloads)
        self.assertGreaterEqual(factory_calls, 2)

    def test_credentials_are_redacted(self) -> None:
        self.assertEqual(
            redact_stream_url("rtsps://device:secret@example.test/live"),
            "rtsps://***:***@example.test/live",
        )
        self.assertEqual(
            redact_stream_url(
                "rtsp://camera/homecam/ai?access_token=secret&mode=low"
            ),
            "rtsp://camera/homecam/ai?access_token=***&mode=low",
        )


if __name__ == "__main__":
    unittest.main()
