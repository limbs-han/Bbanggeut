from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from audio_accuracy_runner import DatasetSample, Prediction
from audio_threshold_tuning import (
    detects_event,
    evaluate_window_gate,
    f_beta,
    main,
    pareto_frontier,
    representative_candidates,
)


def prediction(sample_id: str, index: int, laughter: float, clap: float = 0.0) -> Prediction:
    return Prediction(
        sample_id=sample_id,
        score=laughter,
        scores={"laughter": laughter, "clap": clap},
        latency_ms=1.0,
        duration_seconds=10.0,
        top_class="Laughter",
        window_index=index,
        offset_seconds=float(index),
    )


class AudioThresholdTuningTests(unittest.TestCase):
    def test_f2_weights_recall_more_than_precision(self) -> None:
        self.assertAlmostEqual(f_beta(0.5, 1.0), 5.0 / 6.0)
        self.assertGreater(f_beta(0.5, 1.0), f_beta(1.0, 0.5))

    def test_consecutive_window_gate_resets_after_negative_window(self) -> None:
        rows = [
            prediction("sample", 0, 0.9),
            prediction("sample", 1, 0.1),
            prediction("sample", 2, 0.8),
            prediction("sample", 3, 0.7),
        ]
        self.assertTrue(
            detects_event(
                rows,
                event_type="laughter",
                threshold=0.5,
                required_consecutive_windows=2,
            )
        )
        self.assertFalse(
            detects_event(
                rows,
                event_type="laughter",
                threshold=0.5,
                required_consecutive_windows=3,
            )
        )

    def test_evaluation_applies_same_window_gate_to_recall_and_false_positive(self) -> None:
        samples = [
            DatasetSample("positive", "validation", True, (), 10.0),
            DatasetSample("negative", "validation", False, (), 10.0),
        ]
        rows = {
            "positive": tuple(
                [prediction("positive", 0, 0.9), prediction("positive", 1, 0.8)]
            ),
            "negative": tuple(
                [prediction("negative", 0, 0.9), prediction("negative", 1, 0.1)]
            ),
        }
        results = evaluate_window_gate(
            samples,
            rows,
            event_type="laughter",
            threshold=0.5,
            required_consecutive_windows=2,
        )
        self.assertTrue(results[0].predicted_positive)
        self.assertFalse(results[1].predicted_positive)

    def test_pareto_frontier_removes_dominated_candidate(self) -> None:
        candidates = [
            self.candidate(0.3, recall=1.0, fp_rate=9.0, f2=0.8),
            self.candidate(0.5, recall=0.9, fp_rate=2.0, f2=0.85),
            self.candidate(0.6, recall=0.8, fp_rate=3.0, f2=0.7),
            self.candidate(0.7, recall=0.7, fp_rate=0.0, f2=0.75),
        ]
        frontier = pareto_frontier(candidates)
        self.assertEqual([row["threshold"] for row in frontier], [0.3, 0.5, 0.7])

    def test_shadow_candidate_is_highest_f2_on_frontier(self) -> None:
        candidates = [
            self.candidate(0.3, recall=1.0, fp_rate=9.0, f2=0.8),
            self.candidate(0.5, recall=0.9, fp_rate=2.0, f2=0.9),
            self.candidate(0.7, recall=0.7, fp_rate=0.0, f2=0.75),
        ]
        frontier = pareto_frontier(candidates)
        selected = representative_candidates(candidates, frontier)
        self.assertEqual(selected["maximumRecall"]["threshold"], 0.3)
        self.assertEqual(selected["maximumF2"]["threshold"], 0.5)
        self.assertEqual(selected["shadowCandidate"]["threshold"], 0.5)

    def test_main_writes_sweep_report_and_failure_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dataset_root = root / "dataset"
            results_root = root / "results"
            output_root = root / "tuning"
            dataset_root.mkdir()
            samples = [
                self.dataset_sample("validation-laughter", "validation", ["laughter"], ["laughter"]),
                self.dataset_sample("validation-clap", "validation", ["clap"], ["consecutive-clap"]),
                self.dataset_sample("validation-mixed", "validation", ["laughter", "clap"], ["laughter-with-clap"]),
                self.dataset_sample("validation-noise", "validation", [], ["conversation"]),
                self.dataset_sample("test-laughter", "test", ["laughter"], ["laughter"]),
                self.dataset_sample("test-clap", "test", ["clap"], ["consecutive-clap"]),
                self.dataset_sample("test-mixed", "test", ["laughter", "clap"], ["laughter-with-clap"]),
                self.dataset_sample("test-noise", "test", [], ["conversation"]),
                self.dataset_sample(
                    "test-continuous-negative-quiet-office-001",
                    "test",
                    [],
                    ["quiet-office"],
                    duration=3600.0,
                ),
            ]
            manifest = {"name": "fixture-audio", "samples": samples}
            manifest_path = dataset_root / "dataset.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()

            run_dir = results_root / "round-01" / "fixture-model"
            run_dir.mkdir(parents=True)
            rows = []
            scores = {
                "validation-laughter": (0.9, 0.1),
                "validation-clap": (0.1, 0.9),
                "validation-mixed": (0.8, 0.8),
                "validation-noise": (0.2, 0.2),
                "test-laughter": (0.9, 0.1),
                "test-clap": (0.1, 0.9),
                "test-mixed": (0.8, 0.8),
                "test-noise": (0.2, 0.2),
                "test-continuous-negative-quiet-office-001": (0.1, 0.1),
            }
            for sample_id, (laughter, clap) in scores.items():
                for index in range(2):
                    rows.append(
                        {
                            "schemaVersion": "0.1",
                            "sampleId": sample_id,
                            "score": laughter,
                            "scores": {"laughter": laughter, "clap": clap},
                            "latencyMs": 1.0,
                            "durationSeconds": next(
                                row["durationSeconds"]
                                for row in samples
                                if row["sampleId"] == sample_id
                            ),
                            "topClass": "fixture",
                            "windowIndex": index,
                            "offsetSeconds": float(index),
                        }
                    )
            (run_dir / "predictions.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            (run_dir / "prediction-metadata.json").write_text(
                json.dumps(
                    {
                        "dataset": {"manifestSha256": manifest_hash},
                        "configuration": {
                            "windowSeconds": 1.0,
                            "hopSeconds": 0.5,
                            "precision": "fp32",
                        },
                    }
                ),
                encoding="utf-8",
            )
            for event_type in ("laughter", "clap"):
                evaluation = run_dir / f"evaluation-{event_type}"
                evaluation.mkdir()
                (evaluation / "summary.json").write_text(
                    json.dumps(
                        {
                            "model": {"name": "Fixture", "runtime": "test"},
                            "comparison": {"id": "fixture-comparison", "trialIndex": 1},
                            "configuration": {
                                "threshold": 0.5,
                                "requiredConsecutiveWindows": 2,
                            },
                        }
                    ),
                    encoding="utf-8",
                )

            result = main(
                [
                    "--results-dir",
                    str(results_root),
                    "--dataset-root",
                    str(dataset_root),
                    "--output-dir",
                    str(output_root),
                    "--expected-repeats",
                    "1",
                ]
            )
            self.assertEqual(result, 0)
            self.assertTrue((output_root / "threshold-tuning.json").is_file())
            self.assertTrue((output_root / "threshold-sweep.jsonl").is_file())
            self.assertTrue((output_root / "failure-cases.jsonl").is_file())
            self.assertTrue((output_root / "threshold-tuning.md").is_file())
            payload = json.loads(
                (output_root / "threshold-tuning.json").read_text(encoding="utf-8")
            )
            self.assertEqual(payload["comparisonId"], "fixture-comparison")
            self.assertEqual(payload["models"][0]["model"], "Fixture")
            self.assertEqual(
                payload["models"][0]["mixedEventDiagnostic"]["bothDetectedRateMin"],
                1.0,
            )

    @staticmethod
    def candidate(
        threshold: float,
        *,
        recall: float,
        fp_rate: float,
        f2: float,
    ) -> dict[str, float | int]:
        return {
            "threshold": threshold,
            "requiredConsecutiveWindows": 2,
            "minimumPositiveSpanSeconds": 1.5,
            "recallMin": recall,
            "falsePositiveClipsPerHourMax": fp_rate,
            "f2Mean": f2,
            "precisionMean": 0.8,
        }

    @staticmethod
    def dataset_sample(
        sample_id: str,
        split: str,
        labels: list[str],
        conditions: list[str],
        *,
        duration: float = 10.0,
    ) -> dict[str, object]:
        return {
            "sampleId": sample_id,
            "split": split,
            "labels": labels,
            "conditions": conditions,
            "durationSeconds": duration,
            "review": {"status": "verified"},
        }


if __name__ == "__main__":
    unittest.main()
