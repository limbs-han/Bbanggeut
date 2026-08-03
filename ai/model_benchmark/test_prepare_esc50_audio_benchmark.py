import sys
from pathlib import Path
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

from prepare_esc50_audio_benchmark import (
    event_conditions,
    event_labels,
    safe_member,
)


class PrepareEsc50AudioBenchmarkTests(unittest.TestCase):
    def test_maps_only_laughing_and_clapping_to_event_labels(self):
        self.assertEqual(event_labels("laughing"), ("laughter",))
        self.assertEqual(event_labels("clapping"), ("clap",))
        self.assertEqual(event_labels("door_wood_creaks"), ())
        self.assertIn("external-generalization", event_conditions("laughing"))

    def test_rejects_archive_path_traversal(self):
        self.assertTrue(safe_member("ESC-50/audio/sample.wav"))
        self.assertFalse(safe_member("../outside.txt"))
        self.assertFalse(safe_member("ESC-50/../outside.txt"))


if __name__ == "__main__":
    unittest.main()
