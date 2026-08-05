import sys
from pathlib import Path
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

from audio_negative_capture import CAPTURE_SECONDS, planned_rows


class AudioNegativeCaptureTests(unittest.TestCase):
    def test_plan_is_exactly_one_hour(self):
        rows = planned_rows()

        self.assertEqual(len(rows), 4)
        self.assertEqual(sum(row["durationSeconds"] for row in rows), 3600)
        self.assertEqual(CAPTURE_SECONDS, 900)
        self.assertTrue(all(row["sampleId"].startswith("test-") for row in rows))


if __name__ == "__main__":
    unittest.main()
