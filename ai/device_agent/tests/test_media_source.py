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

    def test_capture_waits_for_the_microphone_too(self) -> None:
        # ffmpeg 가 카메라와 마이크를 한 프로세스에서 열기 때문에, 마이크가
        # busy 이면 영상까지 통째로 죽는다. 카메라만 기다려서는 부족하다.
        self.assertIn("AUDIO_WAIT_ATTEMPTS", self.script)
        camera_wait = self.script.index('while [[ ! -r "$CAMERA_DEVICE" ]]')
        audio_wait = self.script.index('arecord -q -D "$AUDIO_DEVICE"')
        exec_line = self.script.index('exec "$FFMPEG_PATH"')
        self.assertLess(camera_wait, audio_wait)
        self.assertLess(audio_wait, exec_line)


if __name__ == "__main__":
    unittest.main()
