from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess
import unittest

from wj_device_agent.config import AgentConfig
from wj_device_agent.talkback import TalkbackManager


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


def config(**overrides) -> AgentConfig:
    base = dict(
        device_id="11111111-1111-4111-8111-111111111111",
        bearer_token="secret",
        firmware_version="test",
        node_id="pi-gateway",
        mqtt_host="localhost",
        mqtt_port=8883,
        mqtt_environment="test",
        mqtt_ca_cert=Path("ca.crt"),
        publish_url_template="rtsp://localhost/live/{stream_id}",
        media_tls_ca_cert=None,
        ffmpeg_output_args=(),
        ffmpeg_path="ffmpeg",
        ffmpeg_input_args=("-f", "lavfi", "-i", "testsrc"),
        ffmpeg_video_args=("-c:v", "libx264"),
        ffmpeg_audio_input_args=(),
        ffmpeg_audio_args=(),
        ffmpeg_audio_from_primary_input=False,
        ready_delay_seconds=1,
        talkback_url_template="rtsp://localhost/talkback/{stream_id}",
        talkback_command_template=(
            "ffmpeg", "-i", "{url}", "-f", "alsa", "default",
        ),
    )
    base.update(overrides)
    return AgentConfig(**base)


STREAM_ID = "22222222-2222-4222-8222-222222222222"
EXPIRES_AT = datetime(2026, 8, 1, 12, 0, tzinfo=timezone.utc)


class TalkbackManagerTest(unittest.TestCase):
    def test_start_substitutes_the_stream_url_into_the_player_command(self):
        calls = []
        process = FakeProcess()

        def factory(command, **kwargs):
            calls.append(command)
            return process

        manager = TalkbackManager(config(), factory)
        self.assertTrue(manager.start(STREAM_ID, EXPIRES_AT))

        self.assertEqual(
            calls[0],
            [
                "ffmpeg",
                "-i",
                f"rtsp://localhost/talkback/{STREAM_ID}",
                "-f",
                "alsa",
                "default",
            ],
        )
        self.assertTrue(manager.snapshot().running)

    def test_repeated_start_for_the_same_stream_only_extends_the_lease(self):
        started = []

        def factory(command, **kwargs):
            started.append(command)
            return FakeProcess()

        manager = TalkbackManager(config(), factory)
        manager.start(STREAM_ID, EXPIRES_AT)
        extended = EXPIRES_AT + timedelta(seconds=30)

        # 서버는 heartbeat마다 START_TALKBACK을 다시 보낸다. 재생을 끊으면
        # 15초마다 소리가 튄다.
        self.assertFalse(manager.start(STREAM_ID, extended))
        self.assertEqual(len(started), 1)
        self.assertEqual(manager.snapshot().hard_expires_at, extended)

    def test_start_rejects_a_second_stream_while_one_is_playing(self):
        manager = TalkbackManager(config(), lambda command, **kwargs: FakeProcess())
        manager.start(STREAM_ID, EXPIRES_AT)

        with self.assertRaises(RuntimeError) as error:
            manager.start("33333333-3333-4333-8333-333333333333", EXPIRES_AT)
        self.assertEqual(str(error.exception), "DEVICE_BUSY")

    def test_start_without_a_configured_speaker_reports_speaker_unavailable(self):
        manager = TalkbackManager(
            config(talkback_command_template=()),
            lambda command, **kwargs: FakeProcess(),
        )

        with self.assertRaises(RuntimeError) as error:
            manager.start(STREAM_ID, EXPIRES_AT)
        self.assertEqual(str(error.exception), "SPEAKER_UNAVAILABLE")

    def test_stop_terminates_the_player_and_clears_state(self):
        process = FakeProcess()
        manager = TalkbackManager(config(), lambda command, **kwargs: process)
        manager.start(STREAM_ID, EXPIRES_AT)

        self.assertTrue(manager.stop(STREAM_ID))

        self.assertTrue(process.terminated)
        self.assertFalse(manager.snapshot().running)
        self.assertIsNone(manager.snapshot().stream_id)

    def test_stop_without_a_running_player_is_not_an_error(self):
        manager = TalkbackManager(config(), lambda command, **kwargs: FakeProcess())
        self.assertFalse(manager.stop(STREAM_ID))

    def test_stop_rejects_a_stale_stream_id(self):
        manager = TalkbackManager(config(), lambda command, **kwargs: FakeProcess())
        manager.start(STREAM_ID, EXPIRES_AT)

        with self.assertRaises(RuntimeError) as error:
            manager.stop("33333333-3333-4333-8333-333333333333")
        self.assertEqual(str(error.exception), "TALKBACK_NOT_RUNNING")

    def test_clear_if_finished_reports_a_player_that_exited_on_its_own(self):
        process = FakeProcess()
        manager = TalkbackManager(config(), lambda command, **kwargs: process)
        manager.start(STREAM_ID, EXPIRES_AT)
        process.return_code = 1

        finished = manager.clear_if_finished()

        self.assertIsNotNone(finished)
        self.assertEqual(finished.stream_id, STREAM_ID)
        self.assertEqual(finished.return_code, 1)
        self.assertIsNone(manager.clear_if_finished())

    def test_start_rejects_a_non_uuid_stream_id(self):
        manager = TalkbackManager(config(), lambda command, **kwargs: FakeProcess())
        with self.assertRaises(ValueError):
            manager.start("not-a-uuid", EXPIRES_AT)


if __name__ == "__main__":
    unittest.main()
