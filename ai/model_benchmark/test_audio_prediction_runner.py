import csv
import importlib
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest

try:
    import numpy as np
except ImportError:  # Production inference dependency is optional in lightweight CI.
    np = None

from audio_prediction_runner import (
    CLAP_CLASS_NAMES,
    LAUGHTER_CLASS_NAMES,
    checkpoint_state_dict,
    dequantize_tensor,
    event_class_indices,
    laughter_indices,
    load_class_names,
    load_module_file,
    load_manifest_samples,
    quantize_tensor,
    resolve_torch_precision,
    repository_import_path,
    sha256_file,
    window_waveform,
)


class AudioPredictionRunnerTests(unittest.TestCase):
    def test_selects_stable_precision_per_torch_model(self):
        self.assertEqual(
            resolve_torch_precision(
                "auto",
                device_type="cuda",
                model_kind="efficientat-mn10",
            ),
            "fp16-autocast",
        )
        self.assertEqual(
            resolve_torch_precision(
                "auto",
                device_type="cuda",
                model_kind="panns-cnn10",
            ),
            "fp32",
        )
        with self.assertRaisesRegex(ValueError, "non-finite"):
            resolve_torch_precision(
                "fp16",
                device_type="cuda",
                model_kind="panns-cnn10",
            )

    def test_loads_quoted_class_map_and_resolves_names(self):
        with tempfile.TemporaryDirectory() as directory:
            class_map = Path(directory) / "classes.csv"
            with class_map.open("w", encoding="utf-8", newline="") as target:
                writer = csv.writer(target)
                writer.writerow(["index", "mid", "display_name"])
                writer.writerow([0, "/m/zero", "Speech"])
                for index, name in reversed(
                    list(enumerate(LAUGHTER_CLASS_NAMES, start=1))
                ):
                    writer.writerow([index, f"/m/{index}", name])

            names = load_class_names(class_map)

            self.assertEqual(names[-1], "Chuckle, chortle")
            self.assertEqual(laughter_indices(names), (1, 2, 3, 4, 5, 6))

    def test_requires_every_laughter_class_name(self):
        with self.assertRaisesRegex(ValueError, "Baby laughter"):
            laughter_indices(["Laughter", "Speech"])

    def test_resolves_laughter_and_clap_indices_independently(self):
        names = ["Speech", *LAUGHTER_CLASS_NAMES, *CLAP_CLASS_NAMES]

        self.assertEqual(event_class_indices(names, "laughter"), tuple(range(1, 7)))
        self.assertEqual(event_class_indices(names, "clap"), (7, 8))

        with self.assertRaisesRegex(ValueError, "unsupported audio event"):
            event_class_indices(names, "doorbell")

    @unittest.skipIf(np is None, "numpy is not installed in lightweight CI")
    def test_windows_audio_with_overlap_and_zero_padding(self):
        waveform = np.arange(14, dtype=np.float32)

        windows = list(
            window_waveform(
                waveform,
                sample_rate=10,
                window_seconds=0.8,
                hop_seconds=0.4,
            )
        )

        self.assertEqual([index for index, _ in windows], [0, 1, 2])
        self.assertEqual([len(values) for _, values in windows], [8, 8, 8])
        np.testing.assert_array_equal(windows[-1][1][-2:], np.zeros(2))

    @unittest.skipIf(np is None, "numpy is not installed in lightweight CI")
    def test_quantizes_and_dequantizes_tflite_values(self):
        detail = {
            "dtype": np.int8,
            "quantization": (0.1, -3),
        }

        quantized = quantize_tensor(np.array([-0.2, 0.0, 0.4]), detail)
        restored = dequantize_tensor(quantized, detail)

        np.testing.assert_array_equal(quantized, np.array([-5, -3, 1], dtype=np.int8))
        np.testing.assert_allclose(restored, np.array([-0.2, 0.0, 0.4]), atol=1e-6)

    def test_manifest_filters_splits_and_requires_review(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / "sample.wav"
            media.write_bytes(b"wave")
            manifest = {
                "samples": [
                    {
                        "sampleId": "validation-laughter-001",
                        "media": "sample.wav",
                        "sha256": sha256_file(media),
                        "split": "validation",
                        "review": {"status": "verified"},
                    },
                    {
                        "sampleId": "test-laughter-001",
                        "media": "sample.wav",
                        "sha256": sha256_file(media),
                        "split": "test",
                        "review": {"status": "provisional"},
                    },
                ]
            }
            (root / "dataset.json").write_text(
                json.dumps(manifest),
                encoding="utf-8",
            )

            selected = load_manifest_samples(
                root,
                splits={"validation"},
                allow_provisional=False,
            )
            self.assertEqual([row["sampleId"] for row in selected], ["validation-laughter-001"])

            with self.assertRaisesRegex(ValueError, "not verified"):
                load_manifest_samples(
                    root,
                    splits={"test"},
                    allow_provisional=False,
                )

    def test_extracts_nested_and_direct_state_dicts(self):
        nested = {"model": {"layer.weight": object()}}
        direct = {"layer.weight": object()}

        self.assertEqual(checkpoint_state_dict(nested), nested["model"])
        self.assertEqual(checkpoint_state_dict(direct), direct)

    def test_repository_imports_do_not_leak_generic_module_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = root / "first"
            second = root / "second"
            (first / "collision_models").mkdir(parents=True)
            (second / "pytorch").mkdir(parents=True)
            (first / "collision_models" / "__init__.py").write_text(
                "ORIGIN = 'first'\n",
                encoding="utf-8",
            )
            (second / "pytorch" / "collision_models.py").write_text(
                "ORIGIN = 'second'\n",
                encoding="utf-8",
            )

            with repository_import_path(first):
                module = importlib.import_module("collision_models")
                self.assertEqual(module.ORIGIN, "first")

            self.assertNotIn("collision_models", sys.modules)

            with repository_import_path(second):
                module = importlib.import_module("collision_models")
                self.assertEqual(module.ORIGIN, "second")

            self.assertNotIn("collision_models", sys.modules)

    def test_module_file_loading_ignores_generic_module_cache_collision(self):
        with tempfile.TemporaryDirectory() as directory:
            module_path = Path(directory) / "models.py"
            module_path.write_text(
                "class Cnn10:\n"
                "    origin = 'panns-file'\n",
                encoding="utf-8",
            )
            cached = types.ModuleType("models")
            cached.origin = "unrelated-cache"
            previous = sys.modules.get("models")
            sys.modules["models"] = cached
            try:
                loaded = load_module_file(
                    module_path,
                    "_wj_test_panns_models",
                )
                self.assertEqual(loaded.Cnn10.origin, "panns-file")
                self.assertIs(sys.modules["models"], cached)
            finally:
                if previous is None:
                    sys.modules.pop("models", None)
                else:
                    sys.modules["models"] = previous


if __name__ == "__main__":
    unittest.main()
