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


if __name__ == "__main__":
    unittest.main()
