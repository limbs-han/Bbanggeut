"""Tests for the shared local audio-event trigger contract."""

from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest

from audio_event_trigger import (
    build_audio_event_payload,
    write_audio_event_trigger,
)


class AudioEventTriggerTests(unittest.TestCase):
    def test_builds_versioned_clap_trigger(self) -> None:
        payload = build_audio_event_payload(
            event_id="event-1",
            event_type="clap",
            occurred_at=datetime(2026, 7, 30, tzinfo=timezone.utc),
            confidence=0.91,
            class_name="Clapping",
            clip_seconds=60,
            metadata={"positiveWindows": 3},
        )

        self.assertEqual(payload["schemaVersion"], "1.1")
        self.assertEqual(payload["type"], "CLAP")
        self.assertEqual(payload["metadata"]["positiveWindows"], 3)

    def test_writes_trigger_atomically_without_leaving_temp_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            event_dir = Path(temporary_directory)

            destination = write_audio_event_trigger(
                event_dir,
                event_id="event-2",
                event_type="WAKE_WORD",
                occurred_at=datetime.now(timezone.utc),
                confidence=1.0,
                class_name="윌리엄 제임스",
                clip_seconds=60,
            )

            payload = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(payload["type"], "WAKE_WORD")
            self.assertFalse(
                destination.with_suffix(destination.suffix + ".tmp").exists()
            )

    def test_rejects_unknown_event_type(self) -> None:
        with self.assertRaises(ValueError):
            build_audio_event_payload(
                event_id="event-3",
                event_type="NOISE",
                occurred_at=datetime.now(timezone.utc),
                confidence=0.5,
                class_name="Noise",
                clip_seconds=60,
            )


if __name__ == "__main__":
    unittest.main()
