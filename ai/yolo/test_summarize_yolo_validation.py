"""Tests for the YOLO RTSP validation summary."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from summarize_yolo_validation import (
    class_result,
    load_commands,
    markdown_report,
    reconnect_label,
    summarize,
)


class SummarizeYoloValidationTests(unittest.TestCase):
    def test_summarizes_classes_tracking_and_reconnection(self) -> None:
        commands = [
            {
                "state": "HOME",
                "direction": "HOME",
                "object_counts": {"person": 0, "cat": 0, "dog": 0},
                "track_ids": [],
                "sent_at": "2026-07-24T00:00:00.000Z",
            },
            {
                "state": "TRACKING",
                "direction": "RIGHT",
                "object_counts": {"person": 1, "cat": 0, "dog": 1},
                "target_ids": [4, 7],
                "created_at": "2026-07-24T00:00:01.000Z",
            },
            {
                "state": "NO_TARGET_HOLD",
                "direction": "HOLD",
                "object_counts": {"person": 0, "cat": 0, "dog": 0},
                "track_ids": [],
                "sent_at": "2026-07-24T00:00:02.000Z",
            },
            {
                "state": "RETURN_HOME",
                "direction": "HOME",
                "object_counts": {"person": 0, "cat": 0, "dog": 0},
                "track_ids": [],
                "sent_at": "2026-07-24T00:00:08.000Z",
            },
        ]
        log_text = "\n".join(
            [
                "Video stream connected: rtsp://127.0.0.1/homecam/ai",
                "frames=5 fps=5.0 state=TRACKING",
                "Video stream unavailable (RuntimeError); retrying",
                "Video stream reconnected: rtsp://127.0.0.1/homecam/ai",
                "frames=10 fps=6.0 state=HOME",
            ]
        )

        summary = summarize(commands, 0, log_text)

        self.assertEqual(summary["maximum_object_counts"]["person"], 1)
        self.assertEqual(summary["maximum_object_counts"]["dog"], 1)
        self.assertEqual(summary["maximum_object_counts"]["cat"], 0)
        self.assertEqual(summary["unique_track_ids"], [4, 7])
        self.assertEqual(
            summary["first_command_at"],
            "2026-07-24T00:00:00.000Z",
        )
        self.assertEqual(
            summary["last_command_at"],
            "2026-07-24T00:00:08.000Z",
        )
        self.assertTrue(summary["observed_tracking"])
        self.assertTrue(summary["observed_hold_after_tracking"])
        self.assertTrue(summary["observed_home_after_tracking"])
        self.assertEqual(summary["reported_fps_mean"], 5.5)
        self.assertEqual(reconnect_label(summary), "PASS")
        self.assertIn("| cat | NOT OBSERVED |", markdown_report(summary))

    def test_class_not_present_and_not_exercised_is_not_tested(self) -> None:
        self.assertEqual(class_result("cat", False, {"person"}), "NOT TESTED")
        self.assertEqual(class_result("person", False, {"person"}), "NOT OBSERVED")
        self.assertEqual(class_result("dog", True, {"person"}), "PASS")

    def test_load_commands_counts_invalid_lines(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "commands.jsonl"
            path.write_text(
                json.dumps({"state": "HOME"}) + "\nnot-json\n[]\n",
                encoding="utf-8",
            )

            commands, invalid_lines = load_commands(path)

        self.assertEqual(commands, [{"state": "HOME"}])
        self.assertEqual(invalid_lines, 2)

    def test_reconnect_is_not_tested_without_interruption(self) -> None:
        summary = summarize(
            [{"state": "HOME", "direction": "HOME"}],
            0,
            "Video stream connected: rtsp://127.0.0.1/homecam/ai",
        )

        self.assertEqual(reconnect_label(summary), "NOT TESTED")


if __name__ == "__main__":
    unittest.main()
