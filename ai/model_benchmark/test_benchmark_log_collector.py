import json
from pathlib import Path
import tempfile
import unittest

from benchmark_log_collector import (
    BenchmarkCollector,
    CollectorPaths,
    load_jsonl_tail,
    load_benchmark_results,
    parse_tegrastats_line,
    parse_yolo_line,
    percentile,
    summarize_audio,
)


class TegrastatsParserTests(unittest.TestCase):
    def test_parses_jetson_resource_line(self):
        row = parse_tegrastats_line(
            "RAM 4832/7620MB (lfb 63x4MB) CPU [12%@729,8%@729] "
            "GR3D_FREQ 64% cpu@49.5C gpu@52.0C VDD_IN 7213mW/6534mW"
        )

        self.assertEqual(row["ramUsedMb"], 4832)
        self.assertEqual(row["ramTotalMb"], 7620)
        self.assertEqual(row["gpuPercent"], 64)
        self.assertEqual(row["temperatureC"], 52.0)
        self.assertEqual(row["powerMw"], 7213)

    def test_missing_resource_values_stay_null(self):
        row = parse_tegrastats_line(None)
        self.assertTrue(all(value is None for value in row.values()))


class YoloParserTests(unittest.TestCase):
    def test_parses_operational_status_line(self):
        row = parse_yolo_line(
            "frames=908 fps=29.4 state=TRACKING command=RIGHT "
            "targets=2/3 ids=[1, 2] error=(+0.210,-0.040)"
        )

        self.assertEqual(row["frameCount"], 908)
        self.assertEqual(row["fps"], 29.4)
        self.assertEqual(row["state"], "TRACKING")
        self.assertEqual(row["command"], "RIGHT")
        self.assertEqual(row["targetCount"], 2)
        self.assertEqual(row["stableObjectCount"], 3)


class AudioSummaryTests(unittest.TestCase):
    def test_summarizes_latest_score_and_latency(self):
        rows = [
            {
                "selectedScore": 0.1,
                "selectedClass": "Laughter",
                "inferenceMs": 40.0,
            },
            {
                "selectedScore": 0.8,
                "selectedClass": "Laughter",
                "topClass": "Laughter",
                "rms": 0.12,
                "wouldTrigger": True,
                "inferenceMs": 60.0,
            },
        ]

        summary = summarize_audio(rows)

        self.assertEqual(summary["selectedScore"], 0.8)
        self.assertEqual(summary["latencyMeanMs"], 50.0)
        self.assertEqual(summary["latencyP95Ms"], 59.0)
        self.assertEqual(summary["sampleCount"], 2)

    def test_percentile_handles_empty_and_single_values(self):
        self.assertIsNone(percentile([], 0.95))
        self.assertEqual(percentile([7.0], 0.95), 7.0)


class CollectorIntegrationTests(unittest.TestCase):
    def test_builds_snapshot_from_run_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "resources.log").write_text(
                "RAM 4000/7620MB GR3D_FREQ 55% gpu@48.0C VDD_IN 6000mW\n",
                encoding="utf-8",
            )
            (root / "yolo.log").write_text(
                "frames=300 fps=27.5 state=HOLD command=HOLD targets=0/1\n",
                encoding="utf-8",
            )
            diagnostic = {
                "observedAt": "2026-07-30T00:00:00.000Z",
                "selectedScore": 0.3,
                "selectedClass": "Laughter",
                "topClass": "Speech",
                "inferenceMs": 51.25,
            }
            (root / "yamnet_diagnostics.jsonl").write_text(
                json.dumps(diagnostic) + "\n",
                encoding="utf-8",
            )

            snapshot = BenchmarkCollector(CollectorPaths(root)).snapshot()

            self.assertEqual(snapshot["schemaVersion"], "0.1")
            self.assertEqual(snapshot["runId"], root.name)
            self.assertEqual(snapshot["system"]["gpuPercent"], 55)
            self.assertEqual(snapshot["vision"]["fps"], 27.5)
            self.assertEqual(snapshot["audio"]["selectedScore"], 0.3)

    def test_jsonl_reader_skips_invalid_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rows.jsonl"
            path.write_text('{"ok":1}\nnot-json\n{"ok":2}\n', encoding="utf-8")
            self.assertEqual(load_jsonl_tail(path), [{"ok": 1}, {"ok": 2}])

    def test_loads_redacted_benchmark_summaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "vision-yolo11n"
            run.mkdir()
            (run / "summary.json").write_text(
                json.dumps(
                    {
                        "runId": "vision-test",
                        "createdAt": "2026-07-30T00:00:00.000Z",
                        "model": {
                            "name": "YOLO11n",
                            "path": "/private/model.engine",
                            "runtime": "tensorrt",
                        },
                        "dataset": {"name": "office-mix-v1"},
                        "metrics": {"fps": 31.7},
                    }
                ),
                encoding="utf-8",
            )

            rows = load_benchmark_results(root)

            self.assertEqual(rows[0]["model"], "YOLO11n")
            self.assertEqual(rows[0]["metrics"]["fps"], 31.7)
            self.assertNotIn("path", rows[0])


if __name__ == "__main__":
    unittest.main()
