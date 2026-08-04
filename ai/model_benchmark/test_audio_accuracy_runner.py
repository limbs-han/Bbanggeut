"""Tests for model-independent laughter accuracy evaluation."""

from __future__ import annotations

import json
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from audio_accuracy_runner import (
    Counts,
    DatasetSample,
    Prediction,
    aggregate_scores,
    by_cohort,
    evaluate,
    false_event_rate_per_hour,
    metrics_from_counts,
    select_threshold,
)


class AudioAccuracyRunnerTests(unittest.TestCase):
    def test_metrics_from_counts(self) -> None:
        metrics = metrics_from_counts(Counts(8, 2, 1, 9))
        self.assertEqual(metrics["precision"], 0.8)
        self.assertEqual(metrics["recall"], 0.888889)
        self.assertEqual(metrics["f1"], 0.842105)

    def test_score_aggregations(self) -> None:
        values = [0.1, 0.2, 0.9]
        self.assertEqual(aggregate_scores(values, "max"), 0.9)
        self.assertAlmostEqual(aggregate_scores(values, "mean"), 0.4)
        self.assertAlmostEqual(aggregate_scores(values, "p90"), 0.76)

    def test_threshold_is_selected_only_from_calibration_samples(self) -> None:
        samples = [
            DatasetSample("positive", "validation", True, (), 2.0),
            DatasetSample("negative", "validation", False, (), 2.0),
        ]
        grouped = {
            "positive": (0.7, "Laughter", 1, 2.0),
            "negative": (0.3, "Speech", 1, 2.0),
        }
        threshold, metrics = select_threshold(samples, grouped)
        self.assertEqual(threshold, 0.7)
        self.assertEqual(metrics["f1"], 1.0)

    def test_threshold_prioritizes_no_false_positives_after_recall_floor(self) -> None:
        samples = [
            DatasetSample("p1", "validation", True, (), 2.0),
            DatasetSample("p2", "validation", True, (), 2.0),
            DatasetSample("n1", "validation", False, (), 2.0),
        ]
        grouped = {
            "p1": (0.9, "Laughter", 1, 2.0),
            "p2": (0.8, "Laughter", 1, 2.0),
            "n1": (0.75, "Speech", 1, 2.0),
        }

        threshold, metrics = select_threshold(samples, grouped, minimum_recall=0.85)

        self.assertEqual(threshold, 0.8)
        self.assertEqual(metrics["falsePositive"], 0)
        self.assertEqual(metrics["recall"], 1.0)

    def test_counts_false_events_with_consecutive_and_cooldown_gate(self) -> None:
        samples = [DatasetSample("negative", "test", False, (), 60.0)]
        rows = [
            Prediction(
                "negative",
                score,
                {"laughter": score, "clap": 0.1},
                1.0,
                60.0,
                "Laughter",
                index,
                float(index),
            )
            for index, score in enumerate(
                [0.9, 0.9, 0.1, 0.9, 0.9, 0.1, 0.1, 0.9, 0.9]
            )
        ]

        rate, count, duration = false_event_rate_per_hour(
            samples,
            rows,
            event_type="laughter",
            threshold=0.8,
            required_consecutive_windows=2,
            cooldown_seconds=5.0,
            hop_seconds=1.0,
        )

        self.assertEqual(count, 2)
        self.assertEqual(rate, 120.0)
        self.assertEqual(duration, 60.0)

    def test_cohort_metrics_keep_continuous_negatives_separate(self) -> None:
        samples = [
            DatasetSample("test-local-laugh", "test", True, (), 2.0),
            DatasetSample("test-local-noise", "test", False, (), 2.0),
            DatasetSample(
                "test-continuous-negative-quiet-office-001",
                "test",
                False,
                ("quiet-office",),
                3600.0,
            ),
            DatasetSample(
                "esc50-laughing-001",
                "test",
                True,
                ("external-generalization",),
                5.0,
            ),
            DatasetSample(
                "esc50-dog-001",
                "test",
                False,
                ("external-generalization",),
                5.0,
            ),
        ]
        scores = {
            "test-local-laugh": 0.9,
            "test-local-noise": 0.1,
            "test-continuous-negative-quiet-office-001": 0.9,
            "esc50-laughing-001": 0.8,
            "esc50-dog-001": 0.1,
        }
        predictions = [
            Prediction(
                sample.sample_id,
                scores[sample.sample_id],
                {"laughter": scores[sample.sample_id], "clap": 0.1},
                1.0,
                sample.duration_seconds,
                "Laughter",
                0,
                0.0,
            )
            for sample in samples
        ]
        grouped = {
            sample.sample_id: (
                scores[sample.sample_id],
                "Laughter",
                1,
                sample.duration_seconds,
            )
            for sample in samples
        }
        results = evaluate(samples, grouped, 0.5)

        cohorts = by_cohort(
            results,
            grouped,
            predictions,
            event_type="laughter",
            threshold=0.5,
            required_consecutive_windows=1,
            cooldown_seconds=12.0,
            hop_seconds=1.0,
        )

        self.assertEqual(cohorts["localDirect"]["sampleCount"], 2)
        self.assertEqual(cohorts["continuousNegative"]["sampleCount"], 1)
        self.assertEqual(
            cohorts["continuousNegative"]["falseEventsPerHour"], 1.0
        )
        self.assertEqual(cohorts["externalGeneralization"]["sampleCount"], 2)
        self.assertEqual(cohorts["externalGeneralization"]["recall"], 1.0)

    def test_cli_writes_reproducible_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            root = Path(temporary_name)
            dataset_root = root / "dataset"
            dataset_root.mkdir()
            samples = [
                self.sample("val-laugh", "validation", ["laughter"], ["laughter"]),
                self.sample("val-speech", "validation", ["speech"], ["speech"]),
                self.sample("test-laugh", "test", ["laughter"], ["laughter"]),
                self.sample("test-tv", "test", ["tv-playback"], ["tv-playback"]),
            ]
            (dataset_root / "dataset.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": "0.1",
                        "name": "audio-test",
                        "samples": samples,
                    }
                ),
                encoding="utf-8",
            )
            predictions = root / "predictions.jsonl"
            rows = [
                self.prediction("val-laugh", 0.8, 10.0, "Laughter"),
                self.prediction("val-speech", 0.2, 12.0, "Speech"),
                self.prediction("test-laugh", 0.9, 11.0, "Laughter"),
                self.prediction("test-tv", 0.85, 13.0, "Laughter"),
            ]
            predictions.write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            model = root / "model.bin"
            model.write_bytes(b"model")
            metadata = {
                "dataset": {
                    "manifestSha256": hashlib.sha256(
                        (dataset_root / "dataset.json").read_bytes()
                    ).hexdigest()
                },
                "model": {
                    "sha256": hashlib.sha256(model.read_bytes()).hexdigest()
                },
                "configuration": {
                    "windowSeconds": 2.0,
                    "hopSeconds": 0.4875,
                    "precision": "fp32",
                },
                "resources": {
                    "status": "computed",
                    "sampleCount": 2,
                    "gpuPercentMax": 42.0,
                },
            }
            (root / "prediction-metadata.json").write_text(
                json.dumps(metadata),
                encoding="utf-8",
            )
            output = root / "results"
            runner = Path(__file__).with_name("audio_accuracy_runner.py")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(runner),
                    "--dataset-root",
                    str(dataset_root),
                    "--predictions",
                    str(predictions),
                    "--model-name",
                    "TestModel",
                    "--runtime",
                    "test",
                    "--model",
                    str(model),
                    "--output-dir",
                    str(output),
                    "--required-consecutive-windows",
                    "1",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            summary = json.loads(
                (output / "summary.json").read_text(encoding="utf-8")
            )
            operating = summary["accuracy"]["operatingPoint"]
            self.assertEqual(summary["component"], "audio")
            self.assertEqual(summary["configuration"]["threshold"], 0.8)
            self.assertEqual(operating["truePositive"], 1)
            self.assertEqual(operating["falsePositive"], 1)
            self.assertEqual(operating["falsePositivesPerHour"], 1800.0)
            self.assertEqual(summary["metrics"]["inferenceP95Ms"], 12.9)
            self.assertEqual(summary["configuration"]["windowSeconds"], 2.0)
            self.assertEqual(summary["configuration"]["precision"], "fp32")
            self.assertEqual(
                summary["configuration"]["minimumPositiveSpanSeconds"],
                2.0,
            )
            self.assertEqual(summary["resources"]["gpuPercentMax"], 42.0)
            self.assertEqual(
                summary["accuracy"]["byCohort"]["localDirect"]["sampleCount"],
                2,
            )
            self.assertEqual(len(summary["accuracy"]["failureCases"]), 1)
            self.assertTrue((output / "progress.json").is_file())
            self.assertTrue((output / "predictions-evaluated.jsonl").is_file())

    def test_cli_rejects_unreviewed_samples_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_name:
            root = Path(temporary_name)
            dataset_root = root / "dataset"
            dataset_root.mkdir()
            sample = self.sample("test-one", "test", ["speech"], ["speech"])
            sample["review"]["status"] = "provisional"
            (dataset_root / "dataset.json").write_text(
                json.dumps({"name": "test", "samples": [sample]}),
                encoding="utf-8",
            )
            predictions = root / "predictions.jsonl"
            predictions.write_text(
                json.dumps(self.prediction("test-one", 0.1, 1.0, "Speech"))
                + "\n",
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("audio_accuracy_runner.py")),
                    "--dataset-root",
                    str(dataset_root),
                    "--predictions",
                    str(predictions),
                    "--model-name",
                    "TestModel",
                    "--runtime",
                    "test",
                    "--output-dir",
                    str(root / "results"),
                    "--threshold",
                    "0.5",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("not verified", completed.stderr)

    @staticmethod
    def sample(
        sample_id: str,
        split: str,
        labels: list[str],
        conditions: list[str],
    ) -> dict:
        return {
            "sampleId": sample_id,
            "split": split,
            "labels": labels,
            "conditions": conditions,
            "durationSeconds": 2.0,
            "review": {
                "status": "verified",
                "manualReviewRequired": False,
            },
        }

    @staticmethod
    def prediction(
        sample_id: str,
        score: float,
        latency_ms: float,
        top_class: str,
    ) -> dict:
        return {
            "schemaVersion": "0.1",
            "sampleId": sample_id,
            "windowIndex": 0,
            "score": score,
            "scores": {"laughter": score, "clap": 0.05},
            "latencyMs": latency_ms,
            "durationSeconds": 2.0,
            "topClass": top_class,
        }


if __name__ == "__main__":
    unittest.main()
