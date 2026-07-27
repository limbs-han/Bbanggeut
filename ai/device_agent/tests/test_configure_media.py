import unittest

from wj_device_agent.configure_media import build_publish_url


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


if __name__ == "__main__":
    unittest.main()
