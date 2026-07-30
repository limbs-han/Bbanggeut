from pathlib import Path
import unittest


class EdgeAiRecordingStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = (
            Path(__file__).resolve().parent / "run_edge_ai_recording.sh"
        ).read_text(encoding="utf-8")

    def test_yamnet_is_ready_before_uploader_and_yolo_start(self) -> None:
        yamnet_launch = self.script.index('"${YAMNET_COMMAND[@]}"')
        ready = self.script.index(
            "YAMNet ready: first inference telemetry received"
        )
        uploader_launch = self.script.index('"${UPLOADER_COMMAND[@]}"')
        yolo_launch = self.script.index('"${YOLO_COMMAND[@]}"')

        self.assertLess(yamnet_launch, ready)
        self.assertLess(ready, uploader_launch)
        self.assertLess(uploader_launch, yolo_launch)

    def test_readiness_uses_wall_clock_deadline(self) -> None:
        self.assertIn('yamnet_wait_started="$(date +%s)"', self.script)
        self.assertIn('now="$(date +%s)"', self.script)
        self.assertNotIn(
            "yamnet_ready_deadline=$((SECONDS +",
            self.script,
        )

    def test_cleanup_escalates_and_has_no_unbounded_wait(self) -> None:
        cleanup_start = self.script.index("cleanup() {")
        cleanup_end = self.script.index("\n}\ntrap cleanup", cleanup_start)
        cleanup = self.script[cleanup_start:cleanup_end]

        self.assertIn("wait_for_children_to_stop 20", cleanup)
        self.assertIn("wait_for_children_to_stop 8", cleanup)
        self.assertIn('kill -INT "$pid"', cleanup)
        self.assertIn('kill -TERM "$pid"', cleanup)
        self.assertIn('kill -KILL "$pid"', cleanup)
        self.assertNotIn("wait 2>/dev/null", cleanup)


if __name__ == "__main__":
    unittest.main()
