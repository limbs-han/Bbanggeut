import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).parents[1] / "play_talkback_gstreamer.py"
SPEC = importlib.util.spec_from_file_location("play_talkback_gstreamer", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class GStreamerTalkbackPlayerTest(unittest.TestCase):
    def test_build_command_separates_credentials_from_the_location(self):
        command = MODULE.build_command(
            "rtsps://device:p%40ss@media.example.test:8322/talkback/stream-id",
            "plughw:CARD=Device,DEV=0",
        )

        self.assertIn(
            "location=rtsps://media.example.test:8322/talkback/stream-id", command
        )
        self.assertIn("user-id=device", command)
        self.assertIn("user-pw=p@ss", command)
        self.assertIn("device=plughw:CARD=Device,DEV=0", command)
        self.assertNotIn("device:p%40ss", " ".join(command))

    def test_build_command_rejects_a_url_without_credentials(self):
        with self.assertRaisesRegex(ValueError, "credentials"):
            MODULE.build_command("rtsps://media.example.test/talkback/id", "default")


if __name__ == "__main__":
    unittest.main()
