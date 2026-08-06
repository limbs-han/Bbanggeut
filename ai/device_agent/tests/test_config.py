from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from wj_device_agent.config import AgentConfig


DEVICE_ID = "11111111-1111-4111-8111-111111111111"


def base_environment(mqtt_ca: Path) -> dict[str, str]:
    return {
        "DEVICE_ID": DEVICE_ID,
        "DEVICE_BEARER_TOKEN": "secret",
        "MQTT_HOST": "broker.example.test",
        "MQTT_CA_CERT": str(mqtt_ca),
        "MEDIA_PUBLISH_URL_TEMPLATE": "rtsp://127.0.0.1:18554/live/{stream_id}",
    }


class AgentConfigTest(unittest.TestCase):
    def test_jetson_live_relay_uses_webrtc_compatible_opus(self):
        example_path = Path(__file__).resolve().parents[1] / (
            "device-agent.jetson.env.example"
        )
        example = example_path.read_text(encoding="utf-8")

        self.assertIn(
            (
                "FFMPEG_AUDIO_ARGS='[\"-c:a\",\"libopus\",\"-b:a\",\"64k\","
                "\"-ar\",\"48000\",\"-ac\",\"1\",\"-application\","
                "\"lowdelay\"]'"
            ),
            example,
        )

    def test_plaintext_loopback_rollback_does_not_add_tls_options(self):
        with tempfile.TemporaryDirectory() as directory:
            mqtt_ca = Path(directory) / "mqtt-ca.crt"
            mqtt_ca.write_text("test", encoding="utf-8")

            with patch.dict("os.environ", base_environment(mqtt_ca), clear=True):
                config = AgentConfig.from_environment()

            self.assertIsNone(config.media_tls_ca_cert)
            self.assertEqual(config.ffmpeg_output_args, ())

    def test_rtsps_requires_ca_and_adds_explicit_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            mqtt_ca = Path(directory) / "mqtt-ca.crt"
            media_ca = Path(directory) / "mediamtx-ca.crt"
            mqtt_ca.write_text("test", encoding="utf-8")
            media_ca.write_text("test", encoding="utf-8")
            environment = base_environment(mqtt_ca)
            environment.update(
                {
                    "MEDIA_PUBLISH_URL_TEMPLATE": (
                        "rtsps://device:secret@media.example.test:8322/"
                        "live/{stream_id}"
                    ),
                    "MEDIA_TLS_CA_CERT": str(media_ca),
                }
            )

            with patch.dict("os.environ", environment, clear=True):
                config = AgentConfig.from_environment()

            self.assertEqual(config.media_tls_ca_cert, media_ca)
            self.assertEqual(
                config.ffmpeg_output_args,
                ("-tls_verify", "1", "-ca_file", str(media_ca)),
            )

    def test_rtsps_rejects_missing_ca(self):
        with tempfile.TemporaryDirectory() as directory:
            mqtt_ca = Path(directory) / "mqtt-ca.crt"
            mqtt_ca.write_text("test", encoding="utf-8")
            environment = base_environment(mqtt_ca)
            environment["MEDIA_PUBLISH_URL_TEMPLATE"] = (
                "rtsps://device:secret@media.example.test:8322/live/{stream_id}"
            )

            with patch.dict("os.environ", environment, clear=True):
                with self.assertRaisesRegex(ValueError, "MEDIA_TLS_CA_CERT"):
                    AgentConfig.from_environment()

    def test_talkback_is_off_until_a_speaker_is_configured(self):
        with tempfile.TemporaryDirectory() as directory:
            mqtt_ca = Path(directory) / "mqtt-ca.crt"
            mqtt_ca.write_text("test", encoding="utf-8")

            with patch.dict("os.environ", base_environment(mqtt_ca), clear=True):
                config = AgentConfig.from_environment()

            # 스피커가 아직 없는 기기가 조용히 발화를 받아들이면 안 된다.
            self.assertEqual(config.talkback_url_template, "")
            self.assertEqual(config.talkback_command_template, ())

    def test_talkback_reuses_the_publish_credentials_on_the_sibling_path(self):
        with tempfile.TemporaryDirectory() as directory:
            mqtt_ca = Path(directory) / "mqtt-ca.crt"
            mqtt_ca.write_text("test", encoding="utf-8")
            environment = base_environment(mqtt_ca)
            environment["TALKBACK_ENABLED"] = "true"

            with patch.dict("os.environ", environment, clear=True):
                config = AgentConfig.from_environment()

            self.assertEqual(
                config.talkback_url_template,
                "rtsp://127.0.0.1:18554/talkback/{stream_id}",
            )
            self.assertEqual(
                config.talkback_command_template,
                (
                    "/usr/bin/ffmpeg",
                    "-hide_banner", "-nostdin", "-loglevel", "warning",
                    "-rtsp_transport", "tcp",
                    "-i", "{url}",
                    "-f", "alsa", "default",
                ),
            )

    def test_talkback_over_rtsps_verifies_the_media_peer(self):
        with tempfile.TemporaryDirectory() as directory:
            mqtt_ca = Path(directory) / "mqtt-ca.crt"
            mqtt_ca.write_text("test", encoding="utf-8")
            media_ca = Path(directory) / "media-ca.crt"
            media_ca.write_text("test", encoding="utf-8")
            environment = base_environment(mqtt_ca)
            environment["MEDIA_PUBLISH_URL_TEMPLATE"] = (
                "rtsps://device:secret@media.example.test:8322/live/{stream_id}"
            )
            environment["MEDIA_TLS_CA_CERT"] = str(media_ca)
            environment["TALKBACK_ENABLED"] = "true"

            with patch.dict("os.environ", environment, clear=True):
                config = AgentConfig.from_environment()

            self.assertIn("-tls_verify", config.talkback_command_template)
            self.assertIn(str(media_ca), config.talkback_command_template)

    def test_talkback_command_must_carry_the_url_placeholder(self):
        with tempfile.TemporaryDirectory() as directory:
            mqtt_ca = Path(directory) / "mqtt-ca.crt"
            mqtt_ca.write_text("test", encoding="utf-8")
            environment = base_environment(mqtt_ca)
            environment["TALKBACK_ENABLED"] = "true"
            environment["TALKBACK_COMMAND"] = '["ffplay","-nodisp"]'

            with patch.dict("os.environ", environment, clear=True):
                with self.assertRaisesRegex(ValueError, "TALKBACK_COMMAND"):
                    AgentConfig.from_environment()

    def test_talkback_player_can_be_replaced_for_a_laptop_stand_in(self):
        with tempfile.TemporaryDirectory() as directory:
            mqtt_ca = Path(directory) / "mqtt-ca.crt"
            mqtt_ca.write_text("test", encoding="utf-8")
            environment = base_environment(mqtt_ca)
            environment["TALKBACK_ENABLED"] = "true"
            environment["TALKBACK_COMMAND"] = (
                '["ffplay","-nodisp","-autoexit","{url}"]'
            )

            with patch.dict("os.environ", environment, clear=True):
                config = AgentConfig.from_environment()

            self.assertEqual(
                config.talkback_command_template,
                ("ffplay", "-nodisp", "-autoexit", "{url}"),
            )

    def test_talkback_url_placeholder_can_be_embedded_in_an_argument(self):
        with tempfile.TemporaryDirectory() as directory:
            mqtt_ca = Path(directory) / "mqtt-ca.crt"
            mqtt_ca.write_text("test", encoding="utf-8")
            environment = base_environment(mqtt_ca)
            environment["TALKBACK_ENABLED"] = "true"
            environment["TALKBACK_COMMAND"] = (
                '["gst-launch-1.0","rtspsrc","location={url}"]'
            )

            with patch.dict("os.environ", environment, clear=True):
                config = AgentConfig.from_environment()

            self.assertEqual(
                config.talkback_command_template,
                ("gst-launch-1.0", "rtspsrc", "location={url}"),
            )


if __name__ == "__main__":
    unittest.main()
