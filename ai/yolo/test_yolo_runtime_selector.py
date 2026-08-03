from pathlib import Path
import tempfile
import unittest

from yolo_runtime_selector import (
    RuntimeSelectionError,
    select_runtime,
    sha256_file,
)


class YoloRuntimeSelectorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.engine = self.root / "yolov8n.engine"
        self.pytorch = self.root / "yolov8n.pt"
        self.engine.write_bytes(b"engine")
        self.pytorch.write_bytes(b"pytorch")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_auto_prefers_a_validated_engine(self) -> None:
        probed: list[Path] = []

        selection = select_runtime(
            "auto",
            self.engine,
            self.pytorch,
            expected_engine_sha256=sha256_file(self.engine),
            engine_probe=probed.append,
        )

        self.assertEqual(selection.runtime, "tensorrt")
        self.assertEqual(selection.model_path, self.engine.resolve())
        self.assertIsNone(selection.fallback_reason)
        self.assertEqual(probed, [self.engine.resolve()])

    def test_auto_falls_back_when_engine_is_missing(self) -> None:
        selection = select_runtime(
            "auto",
            self.root / "missing.engine",
            self.pytorch,
        )

        self.assertEqual(selection.runtime, "pytorch")
        self.assertEqual(selection.model_path, self.pytorch.resolve())
        self.assertIn("model file not found", selection.fallback_reason or "")

    def test_auto_falls_back_when_engine_hash_does_not_match(self) -> None:
        selection = select_runtime(
            "auto",
            self.engine,
            self.pytorch,
            expected_engine_sha256="0" * 64,
        )

        self.assertEqual(selection.runtime, "pytorch")
        self.assertIn("SHA-256 mismatch", selection.fallback_reason or "")

    def test_auto_falls_back_when_engine_probe_fails(self) -> None:
        def fail_probe(_path: Path) -> None:
            raise RuntimeError("incompatible engine")

        selection = select_runtime(
            "auto",
            self.engine,
            self.pytorch,
            engine_probe=fail_probe,
        )

        self.assertEqual(selection.runtime, "pytorch")
        self.assertIn("startup probe failed", selection.fallback_reason or "")

    def test_strict_tensorrt_does_not_hide_engine_failure(self) -> None:
        with self.assertRaisesRegex(RuntimeSelectionError, "SHA-256 mismatch"):
            select_runtime(
                "tensorrt",
                self.engine,
                self.pytorch,
                expected_engine_sha256="f" * 64,
            )

    def test_pytorch_mode_does_not_probe_engine(self) -> None:
        def unexpected_probe(_path: Path) -> None:
            self.fail("engine probe must not run in pytorch mode")

        selection = select_runtime(
            "pytorch",
            self.root / "missing.engine",
            self.pytorch,
            engine_probe=unexpected_probe,
        )

        self.assertEqual(selection.runtime, "pytorch")
        self.assertEqual(selection.model_path, self.pytorch.resolve())

    def test_invalid_runtime_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeSelectionError, "unsupported"):
            select_runtime(
                "unknown",
                self.engine,
                self.pytorch,
            )

    def test_invalid_hash_is_rejected_in_strict_mode(self) -> None:
        with self.assertRaisesRegex(RuntimeSelectionError, "64 hex"):
            select_runtime(
                "tensorrt",
                self.engine,
                self.pytorch,
                expected_engine_sha256="not-a-sha256",
            )


if __name__ == "__main__":
    unittest.main()
