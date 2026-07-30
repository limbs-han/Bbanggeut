import json
from pathlib import Path
import tempfile
import unittest

from benchmark_dataset import (
    add_sample,
    create_dataset,
    load_dataset,
    validate_dataset,
)


class BenchmarkDatasetTests(unittest.TestCase):
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

    def test_manifest_is_json_serializable(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = create_dataset(Path(directory), "smoke-test")
            self.assertIsInstance(json.dumps(payload), str)


if __name__ == "__main__":
    unittest.main()
