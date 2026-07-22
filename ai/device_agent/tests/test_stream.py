from datetime import datetime, timezone
from pathlib import Path
import subprocess
import unittest

from wj_device_agent.config import AgentConfig
from wj_device_agent.stream import StreamManager


class FakeProcess:
    def __init__(self) -> None:
        self.return_code = None
        self.terminated = False
        self.killed = False

    def poll(self):
        return self.return_code

    def terminate(self):
        self.terminated = True
        self.return_code = 0

    def kill(self):
        self.killed = True
        self.return_code = -9

    def wait(self, timeout=None):
        if self.return_code is None:
            raise subprocess.TimeoutExpired("ffmpeg", timeout)
        return self.return_code


def config() -> AgentConfig:
    return AgentConfig(
        device_id="11111111-1111-4111-8111-111111111111",
        bearer_token="secret",
        firmware_version="test",
        node_id="pi-gateway",
        mqtt_host="localhost",
        mqtt_port=8883,
        mqtt_environment="test",
        mqtt_ca_cert=Path("ca.crt"),
        publish_url_template="rtsp://localhost/live/{stream_id}",
        ffmpeg_path="ffmpeg",
        ffmpeg_input_args=("-f", "lavfi", "-i", "testsrc"),
        ffmpeg_video_args=("-c:v", "libx264"),
        ready_delay_seconds=1,
    )


class StreamManagerTest(unittest.TestCase):
    def test_start_builds_dynamic_path_and_stop_terminates(self):
        calls = []
        process = FakeProcess()

        def factory(command, **kwargs):
            calls.append(command)
            return process

        manager = StreamManager(config(), factory)
        stream_id = "55555555-5555-4555-8555-555555555555"
        expiry = datetime(2030, 1, 1, tzinfo=timezone.utc)

        self.assertTrue(manager.start(stream_id, expiry))
        self.assertIn(f"rtsp://localhost/live/{stream_id}", calls[0])
        self.assertTrue(manager.snapshot().running)
        self.assertTrue(manager.stop(stream_id))
        self.assertTrue(process.terminated)

    def test_same_stream_is_idempotent_and_other_stream_is_rejected(self):
        manager = StreamManager(config(), lambda *args, **kwargs: FakeProcess())
        first = "55555555-5555-4555-8555-555555555555"
        other = "66666666-6666-4666-8666-666666666666"
        expiry = datetime(2030, 1, 1, tzinfo=timezone.utc)

        self.assertTrue(manager.start(first, expiry))
        self.assertFalse(manager.start(first, expiry))
        with self.assertRaisesRegex(RuntimeError, "DEVICE_BUSY"):
            manager.start(other, expiry)


if __name__ == "__main__":
    unittest.main()
