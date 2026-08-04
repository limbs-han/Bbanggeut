import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class AudioComparisonReportTests(unittest.TestCase):
    def test_cli_ranks_models_only_after_both_event_gates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            models = (
                ("YAMNet", 0.90, 0.90, 0.5, 12.0),
                ("EfficientAT MN10", 0.93, 0.92, 0.2, 18.0),
                ("PANNs CNN10", 0.94, 0.80, 0.1, 25.0),
            )
            execution_order = 0
            for trial in range(1, 4):
                for model, f1, recall, fp_rate, latency in models:
                    execution_order += 1
                    for event_type in ("laughter", "clap"):
                        output = (
                            root
                            / f"trial-{trial}"
                            / model.replace(" ", "-")
                            / event_type
                        )
                        output.mkdir(parents=True)
                        (output / "summary.json").write_text(
                            json.dumps(
                                self.summary(
                                    model,
                                    event_type,
                                    trial,
                                    execution_order,
                                    f1,
                                    recall,
                                    fp_rate,
                                    latency,
                                )
                            ),
                            encoding="utf-8",
                        )

            diagnostic = root / "diagnostics" / "failed-run" / "summary.json"
            diagnostic.parent.mkdir(parents=True)
            diagnostic.write_text("{not-a-final-result", encoding="utf-8")

            report_dir = root / "report-output"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("audio_comparison_report.py")),
                    "--results-dir",
                    str(root),
                    "--output-dir",
                    str(report_dir),
                    "--expected-repeats",
                    "3",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            payload = json.loads(
                (report_dir / "comparison.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                payload["selection"]["status"],
                "recommended-pending-concurrent-e2e",
            )
            self.assertEqual(payload["selection"]["selectedModel"], "EfficientAT MN10")
            self.assertEqual(payload["rankings"]["serviceFit"][-1], "PANNs CNN10")
            self.assertEqual(len(payload["models"][0]["events"]), 2)
            self.assertEqual(
                payload["models"][0]["serviceGates"]["recallCohort"],
                "localDirect",
            )
            self.assertEqual(
                payload["models"][0]["serviceGates"]["falsePositiveRateCohort"],
                "continuousNegative",
            )
            efficientat = next(
                row
                for row in payload["models"]
                if row["model"] == "EfficientAT MN10"
            )
            self.assertEqual(efficientat["streaming"]["windowSeconds"], 10.0)
            self.assertEqual(
                efficientat["streaming"]["precision"],
                "fp16-autocast",
            )
            self.assertEqual(
                efficientat["streaming"]["minimumPositiveSpanSeconds"],
                10.0,
            )
            self.assertTrue((report_dir / "comparison.csv").is_file())
            self.assertTrue((report_dir / "comparison.md").is_file())

    def test_cli_rejects_a_missing_repeat(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "trial-1" / "YAMNet" / "laughter"
            output.mkdir(parents=True)
            (output / "summary.json").write_text(
                json.dumps(
                    self.summary(
                        "YAMNet",
                        "laughter",
                        1,
                        1,
                        0.9,
                        0.9,
                        0.2,
                        12.0,
                    )
                ),
                encoding="utf-8",
            )

            completed = self.run_report(root, root / "report-output")

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("has 1 runs; expected 3", completed.stderr)

    def test_cli_rejects_malformed_summary_json(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "trial-1" / "YAMNet" / "laughter"
            output.mkdir(parents=True)
            (output / "summary.json").write_text("{broken", encoding="utf-8")

            completed = self.run_report(root, root / "report-output")

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("ERROR:", completed.stderr)

    @staticmethod
    def run_report(results_dir: Path, output_dir: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("audio_comparison_report.py")),
                "--results-dir",
                str(results_dir),
                "--output-dir",
                str(output_dir),
                "--expected-repeats",
                "3",
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    @staticmethod
    def summary(
        model: str,
        event_type: str,
        trial: int,
        execution_order: int,
        f1: float,
        recall: float,
        fp_rate: float,
        latency: float,
    ) -> dict:
        streaming = {
            "YAMNet": (0.975, 0.4875, 2, 1.4625, "float32"),
            "EfficientAT MN10": (10.0, 2.5, 1, 10.0, "fp16-autocast"),
            "PANNs CNN10": (2.0, 1.0, 2, 3.0, "fp32"),
        }[model]
        configuration = {
            "scoreAggregation": "max",
            "windowSeconds": streaming[0],
            "hopSeconds": streaming[1],
            "requiredConsecutiveWindows": streaming[2],
            "minimumPositiveSpanSeconds": streaming[3],
        }
        if trial > 1:
            configuration["precision"] = streaming[4]
        return {
            "component": "audio",
            "runId": f"{model}-{event_type}-{trial}",
            "comparison": {
                "id": "audio-test-comparison",
                "trialIndex": trial,
                "trialCount": 3,
                "executionOrder": execution_order,
            },
            "model": {"name": model, "runtime": "test"},
            "dataset": {
                "name": "audio-test-v1",
                "manifestSha256": "dataset-sha",
            },
            "configuration": configuration,
            "predictionMetadata": {
                "configuration": {
                    "precision": streaming[4],
                },
            },
            "metrics": {
                "inferenceMeanMs": latency - 2,
                "inferenceP95Ms": latency,
            },
            "accuracy": {
                "eventType": event_type,
                "operatingPoint": {
                    "threshold": 0.5,
                    "precision": f1,
                    "recall": recall,
                    "f1": f1,
                    "falsePositivesPerHour": fp_rate,
                    "falseEventCount": 1,
                },
                "byCohort": {
                    "localDirect": {
                        "sampleCount": 60,
                        "precision": f1,
                        "recall": recall,
                        "f1": f1,
                        "falseEventsPerHour": fp_rate,
                        "falseEventCount": 1,
                        "negativeDurationSeconds": 200,
                    },
                    "continuousNegative": {
                        "sampleCount": 4,
                        "precision": 0.0,
                        "recall": 0.0,
                        "f1": 0.0,
                        "falseEventsPerHour": fp_rate,
                        "falseEventCount": 1,
                        "negativeDurationSeconds": 3600,
                    },
                    "externalGeneralization": {
                        "sampleCount": 2000,
                        "precision": f1,
                        "recall": recall,
                        "f1": f1,
                        "falseEventsPerHour": fp_rate,
                        "falseEventCount": 1,
                        "negativeDurationSeconds": 9600,
                    },
                },
                "failureCases": [],
            },
            "resources": {
                "gpuPercentMax": 50,
                "ramUsedMbMax": 3000,
                "temperatureCMax": 50,
                "powerMwMax": 6000,
            },
        }


if __name__ == "__main__":
    unittest.main()
