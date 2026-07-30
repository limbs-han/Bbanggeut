from pathlib import Path
import os
import tempfile
import unittest

from wj_device_agent.provision import (
    DeviceApi,
    parser,
    read_environment,
    update_environment,
    validate_credential,
)


DEVICE_ID = "11111111-1111-4111-8111-111111111111"


class ProvisionTest(unittest.TestCase):
    def test_registration_code_supports_machine_readable_output(self):
        args = parser().parse_args(
            [
                "--api-base-url",
                "https://example.test",
                "registration-code",
                "--output-format",
                "json",
            ],
        )

        self.assertEqual(args.output_format, "json")

    def test_api_uses_expected_enrollment_contract(self):
        calls = []

        def transport(method, url, token, context):
            calls.append((method, url, token))
            return {}

        DeviceApi("https://example.test", transport=transport).enroll("bootstrap-secret")

        self.assertEqual(
            calls,
            [("POST", "https://example.test/api/iot/enrollment", "bootstrap-secret")],
        )

    def test_environment_update_preserves_configuration_and_uses_mode_600(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "agent.env"
            path.write_text("MQTT_HOST=broker.test\nDEVICE_ID=old\n", encoding="utf-8")

            update_environment(path, {
                "DEVICE_ID": DEVICE_ID,
                "DEVICE_BEARER_TOKEN": "wj_key.secret",
            })

            values = read_environment(path)
            self.assertEqual(values["MQTT_HOST"], "broker.test")
            self.assertEqual(values["DEVICE_ID"], DEVICE_ID)
            self.assertEqual(values["DEVICE_BEARER_TOKEN"], "wj_key.secret")
            if os.name == "posix":
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_environment_reader_removes_systemd_style_outer_quotes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "agent.env"
            path.write_text(
                "FFMPEG_INPUT_ARGS='[\"-i\",\"rtsp://127.0.0.1/homecam\"]'\n"
                'NODE_ID="pi-gateway"\n',
                encoding="utf-8",
            )

            values = read_environment(path)

            self.assertEqual(
                values["FFMPEG_INPUT_ARGS"],
                '["-i","rtsp://127.0.0.1/homecam"]',
            )
            self.assertEqual(values["NODE_ID"], "pi-gateway")

    def test_credential_response_is_validated(self):
        values = validate_credential({
            "deviceId": DEVICE_ID,
            "bearerToken": "wj_key.secret",
            "purpose": "OPERATING",
            "expiresAt": "2026-08-21T00:00:00Z",
        })

        self.assertEqual(values["DEVICE_ID"], DEVICE_ID)
        self.assertEqual(values["DEVICE_CREDENTIAL_EXPIRES_AT"], "2026-08-21T00:00:00Z")


if __name__ == "__main__":
    unittest.main()
