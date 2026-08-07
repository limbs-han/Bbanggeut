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

    def test_asymmetric_window_records_each_side_separately(self) -> None:
        # The dashboard button records forward from the press, so the two
        # sides are not equal. The uploader has always read them separately.
        payload = build_audio_event_payload(
            event_id="event-manual",
            event_type="LAUGHTER",
            occurred_at=datetime(2026, 8, 7, tzinfo=timezone.utc),
            confidence=1.0,
            class_name="Manual",
            pre_seconds=1.0,
            post_seconds=120.0,
        )

        self.assertEqual(payload["preSeconds"], 1.0)
        self.assertEqual(payload["postSeconds"], 120.0)

    def test_clip_seconds_still_produces_a_centred_window(self) -> None:
        payload = build_audio_event_payload(
            event_id="event-detector",
            event_type="LAUGHTER",
            occurred_at=datetime(2026, 8, 7, tzinfo=timezone.utc),
            confidence=0.5,
            class_name="Laughter",
            clip_seconds=60,
        )

        self.assertEqual(payload["preSeconds"], 60)
        self.assertEqual(payload["postSeconds"], 60)

    def test_window_arguments_cannot_be_mixed_or_half_given(self) -> None:
        base = {
            "event_id": "event-bad",
            "event_type": "LAUGHTER",
            "occurred_at": datetime(2026, 8, 7, tzinfo=timezone.utc),
            "confidence": 1.0,
            "class_name": "Manual",
        }
        for extra in (
            {"clip_seconds": 60, "post_seconds": 120.0},
            {"post_seconds": 120.0},
            {"pre_seconds": 1.0},
            {},
            {"pre_seconds": 0.0, "post_seconds": 120.0},
        ):
            with self.subTest(extra=sorted(extra)):
                with self.assertRaises(ValueError):
                    build_audio_event_payload(**base, **extra)

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
