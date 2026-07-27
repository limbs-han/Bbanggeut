"""Tests for laughter evaluation sample tooling."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest

from laughter_eval_dataset import (
    build_audio_command,
    catalog_dataset,
    create_sample,
    finalize_sample,
    sha256,
    validate_annotation_bounds,
    validate_sample,
)


class LaughterEvalDatasetTests(unittest.TestCase):
    def metadata_payload(self, sample_dir: Path, sample_id: str = "sample-1") -> dict:
        artifact = sample_dir / "audio_16k_mono.wav"
        artifact.write_bytes(b"audio")
        return {
            "schemaVersion": "1.0",
            "sampleId": sample_id,
            "environment": {
                "name": "test",
                "captureDevice": "test microphone",
                "targetDeviceValidation": False,
            },
            "source": {"requestedDurationSeconds": 12.0},
            "groundTruth": {
                "label": "laughter",
                "annotationStatus": "provisional",
                "startSeconds": 3.0,
                "endSeconds": 9.0,
                "manualReviewRequired": True,
            },
            "result": {"classification": "false_negative"},
            "files": {
                artifact.name: {
                    "sha256": sha256(artifact),
                    "sizeBytes": artifact.stat().st_size,
                }
            },
        }

    def write_metadata(
        self,
        sample_dir: Path,
        sample_id: str = "sample-1",
    ) -> dict:
        payload = self.metadata_payload(sample_dir, sample_id)
        (sample_dir / "metadata.json").write_text(
            json.dumps(payload),
            encoding="utf-8",
        )
        return payload

    def test_annotation_bounds_are_strict(self) -> None:
        validate_annotation_bounds(0.0, 1.0, 1.0)
        with self.assertRaises(ValueError):
            validate_annotation_bounds(-0.1, 1.0, 2.0)
        with self.assertRaises(ValueError):
            validate_annotation_bounds(1.0, 1.0, 2.0)
        with self.assertRaises(ValueError):
            validate_annotation_bounds(1.0, 2.1, 2.0)

    def test_audio_command_converts_only_audio_to_16khz_mono(self) -> None:
        command = build_audio_command(
            "/usr/bin/ffmpeg",
            Path("source.ts"),
            Path("audio.wav"),
            3.918,
            12.014,
        )
        self.assertEqual(command[command.index("-ac") + 1], "1")
        self.assertEqual(command[command.index("-ar") + 1], "16000")
        self.assertEqual(command[command.index("-c:a") + 1], "pcm_s16le")
        self.assertNotIn("-map", command[: command.index("-i")])

    def test_create_is_atomic_and_writes_standard_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            root = Path(temporary_name)
            source = root / "recording.ts"
            source.write_bytes(b"source")
            diagnostics = root / "diagnostics.jsonl"
            diagnostics.write_text("{}\n", encoding="utf-8")
            output = root / "sample"

            def fake_runner(command: list[str], **kwargs: object) -> None:
                self.assertTrue(kwargs["check"])
                Path(command[-1]).write_bytes(b"generated")

            args = argparse.Namespace(
                source_segment=str(source),
                output_dir=str(output),
                sample_id="sample-1",
                environment="home",
                capture_device="generic webcam",
                target_device="Logitech BRIO 100",
                target_device_validation=False,
                segment_started_at="2026-07-26T15:07:11Z",
                context_offset_seconds=3.918,
                context_duration_seconds=12.014,
                label="laughter",
                label_start_seconds=3.0,
                label_end_seconds=9.014,
                annotation_status="provisional",
                annotation_source="operator_prompt_window",
                result="false_negative",
                score_aggregation="mean",
                threshold=0.125,
                consecutive=3,
                gain=1.5,
                maximum_selected_score=0.008764,
                maximum_positive_streak=0,
                maximum_rms=0.257126,
                observed_top_class=["Speech"],
                diagnostics_jsonl=str(diagnostics),
                operator_window=None,
                note=["test sample"],
                ffmpeg="/usr/bin/ffmpeg",
            )

            created = create_sample(args, runner=fake_runner)

            self.assertEqual(created, output.resolve())
            self.assertTrue((created / "metadata.json").is_file())
            self.assertTrue((created / "source_segment.ts").is_file())
            self.assertTrue((created / "context.mp4").is_file())
            self.assertTrue((created / "audio_16k_mono.wav").is_file())
            self.assertTrue((created / "waveform.png").is_file())
            self.assertEqual(validate_sample(created)["sampleId"], "sample-1")

    def test_create_refuses_existing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            root = Path(temporary_name)
            source = root / "recording.ts"
            source.write_bytes(b"source")
            output = root / "sample"
            output.mkdir()
            args = argparse.Namespace(
                source_segment=str(source),
                output_dir=str(output),
                sample_id="sample-1",
            )
            with self.assertRaisesRegex(ValueError, "already exists"):
                create_sample(args)

    def test_finalize_marks_manual_review_and_adds_new_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            sample_dir = Path(temporary_name)
            self.write_metadata(sample_dir)
            waveform = sample_dir / "waveform.png"
            waveform.write_bytes(b"png")

            payload = finalize_sample(
                sample_dir,
                start_seconds=4.5,
                end_seconds=10.5,
                audio_clarity="clear",
                reviewed_at="2026-07-26T15:30:00Z",
            )

            self.assertEqual(payload["groundTruth"]["annotationStatus"], "verified")
            self.assertFalse(payload["groundTruth"]["manualReviewRequired"])
            self.assertEqual(payload["groundTruth"]["startSeconds"], 4.5)
            self.assertEqual(payload["review"]["audioClarity"], "clear")
            self.assertIn("waveform.png", payload["files"])

    def test_validate_detects_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            sample_dir = Path(temporary_name)
            self.write_metadata(sample_dir)
            (sample_dir / "audio_16k_mono.wav").write_bytes(b"changed")

            with self.assertRaisesRegex(ValueError, "size mismatch"):
                validate_sample(sample_dir)

    def test_catalog_writes_json_csv_and_markdown(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            root = Path(temporary_name)
            sample_dir = root / "home" / "sample"
            sample_dir.mkdir(parents=True)
            self.write_metadata(sample_dir)
            output = root / "catalog"

            entries = catalog_dataset(
                root,
                output,
                generated_at=datetime(2026, 7, 26, tzinfo=timezone.utc),
            )

            self.assertEqual(len(entries), 1)
            self.assertTrue((output / "catalog.json").is_file())
            self.assertTrue((output / "catalog.csv").is_file())
            self.assertTrue((output / "catalog.md").is_file())
            catalog = json.loads(
                (output / "catalog.json").read_text(encoding="utf-8")
            )
            self.assertEqual(catalog["sampleCount"], 1)

    def test_catalog_rejects_duplicate_sample_ids(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            root = Path(temporary_name)
            for name in ("one", "two"):
                sample_dir = root / name
                sample_dir.mkdir()
                self.write_metadata(sample_dir, "duplicate")

            with self.assertRaisesRegex(ValueError, "duplicate sampleId"):
                catalog_dataset(root)


if __name__ == "__main__":
    unittest.main()
