from pathlib import Path
import tempfile
import unittest

from wj_device_agent.configure_media import (
    build_publish_url,
    read_credentials_environment,
    read_sha256_fingerprint,
)


class ConfigureMediaTest(unittest.TestCase):
    def test_credentials_are_percent_encoded(self):
        value = build_publish_url(
            "pi user",
            "p@ss/word",
            "media.example.test",
            8322,
        )

        self.assertEqual(
            value,
            "rtsps://pi%20user:p%40ss%2Fword@media.example.test:8322/live/{stream_id}",
        )

    def test_host_must_not_contain_a_scheme_or_port(self):
        with self.assertRaises(ValueError):
            build_publish_url("user", "password", "https://media.example.test", 8322)
        with self.assertRaises(ValueError):
            build_publish_url("user", "password", "media.example.test:8322", 8322)

    def test_port_is_validated(self):
        with self.assertRaises(ValueError):
            build_publish_url("user", "password", "media.example.test", 0)

    def test_authenticated_plain_rtsp_can_be_built_for_ssh_tunnel_rollback(self):
        value = build_publish_url(
            "jetson",
            "secret",
            "127.0.0.1",
            18554,
            "rtsp",
        )

        self.assertEqual(
            value,
            "rtsp://jetson:secret@127.0.0.1:18554/live/{stream_id}",
        )

    def test_protected_credentials_environment_is_supported(self):
        with tempfile.TemporaryDirectory() as directory:
            credentials = Path(directory) / "jetson-mediamtx-credentials.env"
            credentials.write_text(
                "MEDIAMTX_JETSON_PUBLISH_USER=wj-jetson-001\n"
                "MEDIAMTX_JETSON_PUBLISH_PASSWORD=p@ss/word\n",
                encoding="utf-8",
            )
            credentials.chmod(0o600)

            self.assertEqual(
                read_credentials_environment(credentials),
                ("wj-jetson-001", "p@ss/word"),
            )

    def test_credentials_environment_requires_both_values(self):
        with tempfile.TemporaryDirectory() as directory:
            credentials = Path(directory) / "jetson-mediamtx-credentials.env"
            credentials.write_text(
                "MEDIAMTX_JETSON_PUBLISH_USER=wj-jetson-001\n",
                encoding="utf-8",
            )
            credentials.chmod(0o600)

            with self.assertRaisesRegex(ValueError, "must contain"):
                read_credentials_environment(credentials)

    def test_ca_fingerprint_file_is_normalized(self):
        with tempfile.TemporaryDirectory() as directory:
            fingerprint = Path(directory) / "mediamtx-ca.sha256"
            fingerprint.write_text("ab" * 32 + "\n", encoding="utf-8")

            self.assertEqual(
                read_sha256_fingerprint(fingerprint),
                ":".join(["AB"] * 32),
            )

    def test_invalid_ca_fingerprint_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            fingerprint = Path(directory) / "mediamtx-ca.sha256"
            fingerprint.write_text("not-a-fingerprint\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "SHA-256"):
                read_sha256_fingerprint(fingerprint)


if __name__ == "__main__":
    unittest.main()
