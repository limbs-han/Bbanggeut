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
            self.assertTrue((report_dir / "comparison.csv").is_file())
            self.assertTrue((report_dir / "comparison.md").is_file())

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
            "configuration": {"scoreAggregation": "max"},
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
