import json
import multiprocessing
from pathlib import Path
import tempfile
import unittest

from benchmark_dataset import (
    add_sample,
    create_dataset,
    load_dataset,
    review_sample,
    validate_dataset,
)


def add_sample_in_process(root_value: str, index: int) -> None:
    root = Path(root_value)
    sample_id = f"concurrent-sample-{index:03d}"
    media = root / f"{sample_id}.wav"
    media.write_bytes(f"audio-{index}".encode())
    add_sample(
        root=root,
        sample_id=sample_id,
        media_path=media,
        split="test",
        conditions=["laughter"],
        labels=["laughter"],
        notes=None,
    )


class BenchmarkDatasetTests(unittest.TestCase):
    def test_accepts_laughter_with_clap_condition_and_multiple_labels(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            create_dataset(root, "audio-mixed-events")
            media = root / "mixed.wav"
            media.write_bytes(b"mixed-audio")

            sample = add_sample(
                root,
                sample_id="validation-laughter-with-clap-001",
                media_path=media,
                split="validation",
                conditions=["laughter-with-clap"],
                labels=["laughter", "consecutive-clap"],
                notes="simultaneous laughter and clapping",
            )

            self.assertEqual(
                sample["conditions"],
                ["laughter-with-clap"],
            )
            self.assertEqual(
                sample["labels"],
                ["consecutive-clap", "laughter"],
            )
            self.assertEqual(validate_dataset(root), [])

    def test_creates_adds_and_validates_sample(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media_dir = root / "media"
            media_dir.mkdir()
            media_path = media_dir / "scene.mp4"
            media_path.write_bytes(b"benchmark-media")

            create_dataset(root, "office-mix-v1")
            sample = add_sample(
                root=root,
                sample_id="office-two-people-001",
                media_path=media_path,
                split="test",
                conditions=["two-people", "movement"],
                labels=["person:2", "laughter:false"],
                notes="BRIO 100 local capture",
            )

            self.assertEqual(sample["media"], "media/scene.mp4")
            self.assertEqual(sample["review"]["status"], "provisional")
            self.assertEqual(validate_dataset(root), [])
            self.assertEqual(len(load_dataset(root)["samples"]), 1)

    def test_rejects_media_outside_dataset_root(self):
        with tempfile.TemporaryDirectory() as dataset_directory:
            with tempfile.TemporaryDirectory() as media_directory:
                root = Path(dataset_directory)
                media = Path(media_directory) / "outside.wav"
                media.write_bytes(b"audio")
                create_dataset(root, "audio-test")

                with self.assertRaisesRegex(ValueError, "inside the dataset root"):
                    add_sample(
                        root=root,
                        sample_id="outside-audio-001",
                        media_path=media,
                        split="test",
                        conditions=["laughter"],
                        labels=["laughter"],
                        notes=None,
                    )

    def test_detects_changed_media(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "sample.wav"
            media.write_bytes(b"first")
            create_dataset(root, "audio-test")
            add_sample(
                root=root,
                sample_id="laughter-clear-001",
                media_path=media,
                split="test",
                conditions=["laughter"],
                labels=["laughter"],
                notes=None,
            )

            media.write_bytes(b"changed")
            errors = validate_dataset(root)
            self.assertTrue(any("sha256 mismatch" in error for error in errors))
            self.assertTrue(any("sizeBytes mismatch" in error for error in errors))

    def test_rejects_duplicate_sample_id(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "sample.mp4"
            media.write_bytes(b"video")
            create_dataset(root, "vision-test")
            arguments = dict(
                root=root,
                sample_id="single-person-001",
                media_path=media,
                split="test",
                conditions=["single-person"],
                labels=["person:1"],
                notes=None,
            )
            add_sample(**arguments)
            with self.assertRaisesRegex(ValueError, "duplicate sample ID"):
                add_sample(**arguments)

    def test_review_records_verified_status_and_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "sample.wav"
            media.write_bytes(b"audio")
            create_dataset(root, "audio-test")
            add_sample(
                root=root,
                sample_id="laughter-clear-001",
                media_path=media,
                split="validation",
                conditions=["small-laughter"],
                labels=["laughter"],
                notes=None,
            )

            sample = review_sample(
                root,
                "laughter-clear-001",
                status="verified",
                duration_seconds=10.0,
            )

            self.assertEqual(sample["review"]["status"], "verified")
            self.assertFalse(sample["review"]["manualReviewRequired"])
            self.assertEqual(sample["durationSeconds"], 10.0)
            self.assertEqual(validate_dataset(root), [])

    def test_detects_session_leakage_across_splits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            create_dataset(root, "audio-test")
            for sample_id, split in (
                ("validation-laugh-001", "validation"),
                ("test-laugh-001", "test"),
            ):
                media = root / f"{sample_id}.wav"
                media.write_bytes(sample_id.encode())
                add_sample(
                    root=root,
                    sample_id=sample_id,
                    media_path=media,
                    split=split,
                    conditions=["laughter"],
                    labels=["laughter"],
                    notes=None,
                    session_id="office-session-001",
                )

            errors = validate_dataset(root)

            self.assertIn(
                "sessionId office-session-001 appears in multiple splits: "
                "test, validation",
                errors,
            )

    def test_concurrent_adds_are_serialized_without_lost_updates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            create_dataset(root, "concurrent-audio-test")
            context = multiprocessing.get_context("spawn")
            processes = [
                context.Process(
                    target=add_sample_in_process,
                    args=(str(root), index),
                )
                for index in range(6)
            ]

            for process in processes:
                process.start()
            for process in processes:
                process.join(timeout=20)
                self.assertFalse(process.is_alive())
                self.assertEqual(process.exitcode, 0)

            payload = load_dataset(root)
            self.assertEqual(len(payload["samples"]), 6)
            self.assertEqual(validate_dataset(root), [])
            self.assertEqual(list(root.glob(".dataset.*.tmp")), [])

    def test_external_source_requires_dataset_and_license(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "sample.wav"
            media.write_bytes(b"audio")
            create_dataset(root, "audio-test")

            with self.assertRaisesRegex(ValueError, "must be provided together"):
                add_sample(
                    root=root,
                    sample_id="external-clap-001",
                    media_path=media,
                    split="test",
                    conditions=["external-generalization"],
                    labels=["clap"],
                    notes=None,
                    source_dataset="ESC-50",
                )

    def test_manifest_is_json_serializable(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = create_dataset(Path(directory), "smoke-test")
            self.assertIsInstance(json.dumps(payload), str)


if __name__ == "__main__":
    unittest.main()
