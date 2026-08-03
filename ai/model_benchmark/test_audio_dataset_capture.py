import sys
from pathlib import Path
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

from audio_dataset_capture import (
    build_capture_command,
    initialize,
    load_plan,
    verify_plan,
)
from benchmark_dataset import load_dataset


class AudioDatasetCaptureTests(unittest.TestCase):
    def test_capture_command_rebuilds_monotonic_pts_and_exact_sample_count(self):
        command = build_capture_command(
            "rtsp://127.0.0.1:8554/homecam/ai",
            Path("sample.wav.tmp"),
            10,
        )

        audio_filter = command[command.index("-af") + 1]
        self.assertIn("aresample=48000", audio_filter)
        self.assertEqual(audio_filter.count("asetpts=N/SR/TB"), 2)
        self.assertIn("apad=whole_len=480000", audio_filter)
        self.assertIn("atrim=end_sample=480000", audio_filter)
        self.assertEqual(command[command.index("-t") + 1], "10")

    def test_plan_contains_expected_120_balanced_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            initialize(root, "office-audio-events-v1")

            verify_plan(root)
            plan = load_plan(root)

            self.assertEqual(len(plan["samples"]), 120)
            self.assertEqual(
                sum(row["split"] == "validation" for row in plan["samples"]), 60
            )
            self.assertEqual(
                sum(row["split"] == "test" for row in plan["samples"]), 60
            )
            self.assertEqual(load_dataset(root)["samples"], [])

    def test_validation_and_test_use_distinct_session_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            initialize(root, "office-audio-events-v1")
            rows = load_plan(root)["samples"]

            validation = {row["sessionId"] for row in rows if row["split"] == "validation"}
            test = {row["sessionId"] for row in rows if row["split"] == "test"}

            self.assertTrue(validation)
            self.assertTrue(test)
            self.assertTrue(validation.isdisjoint(test))


if __name__ == "__main__":
    unittest.main()
