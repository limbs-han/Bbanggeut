from pathlib import Path
import unittest


class MediaSourceTimestampTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        script_path = Path(__file__).resolve().parents[1] / "media-source.sh"
        cls.script = script_path.read_text(encoding="utf-8")

    def test_video_capture_uses_absolute_timestamps(self) -> None:
        self.assertIn('-timestamps abs', self.script)

    def test_video_and_audio_keep_their_wallclock_offset(self) -> None:
        self.assertIn("-loglevel warning -copyts", self.script)
        self.assertIn('-af "aresample=async=1"', self.script)
        self.assertNotIn("setpts=PTS-STARTPTS", self.script)
        self.assertNotIn("asetpts=PTS-STARTPTS", self.script)
        self.assertNotIn("first_pts=0", self.script)


if __name__ == "__main__":
    unittest.main()
