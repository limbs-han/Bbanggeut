import http.client
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from benchmark_log_collector import (
    BenchmarkCollector,
    CollectorPaths,
    DEFAULT_PORT,
    SCHEMA_VERSION,
    build_handler,
    latest_run_directory,
    load_jsonl_tail,
    load_benchmark_progress,
    load_benchmark_results,
    parse_request_route,
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
            self.assertTrue(snapshot["freshness"]["available"])
            self.assertFalse(snapshot["freshness"]["stale"])

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

    def test_loads_latest_benchmark_progress_without_private_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / "vision-yolo11n"
            run.mkdir()
            (run / "progress.json").write_text(
                json.dumps(
                    {
                        "schemaVersion": "0.1",
                        "runId": "vision-test",
                        "updatedAt": "2026-07-30T00:00:00.000Z",
                        "status": "running",
                        "component": "vision",
                        "model": "YOLO11n",
                        "runtime": "tensorrt",
                        "dataset": "office-mix-v1",
                        "progress": {
                            "completedFrames": 50,
                            "totalFrames": 100,
                            "percent": 50,
                        },
                        "current": {"sampleId": "office-one"},
                        "modelPath": "/private/model.engine",
                    }
                ),
                encoding="utf-8",
            )

            progress = load_benchmark_progress(root)

            self.assertEqual(progress["model"], "YOLO11n")
            self.assertEqual(progress["progress"]["percent"], 50)
            self.assertNotIn("modelPath", progress)

    def test_follows_newest_active_run_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            older = root / "20260730_100000"
            newer = root / "20260730_110000"
            older.mkdir()
            newer.mkdir()
            (older / "yolo.log").write_text(
                "frames=1 fps=10.0 state=HOLD command=HOLD targets=0/0\n",
                encoding="utf-8",
            )
            (newer / "yolo.log").write_text(
                "frames=2 fps=20.0 state=TRACKING command=LEFT targets=1/1\n",
                encoding="utf-8",
            )
            (older / "resources.log").write_text(
                "RAM 4000/7620MB GR3D_FREQ 55%\n",
                encoding="utf-8",
            )
            os.utime(older / "yolo.log", (100, 100))
            os.utime(newer / "yolo.log", (200, 200))
            os.utime(older / "resources.log", (300, 300))

            self.assertEqual(latest_run_directory(root), newer)
            snapshot = BenchmarkCollector(
                CollectorPaths(logs_root=root)
            ).snapshot()

            self.assertEqual(snapshot["runId"], newer.name)
            self.assertEqual(snapshot["vision"]["fps"], 20.0)

    def test_marks_old_sources_stale(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resources = root / "resources.log"
            resources.write_text(
                "RAM 4000/7620MB GR3D_FREQ 55%\n",
                encoding="utf-8",
            )
            os.utime(resources, (100, 100))

            snapshot = BenchmarkCollector(
                CollectorPaths(root),
                stale_after_seconds=1,
            ).snapshot()

            self.assertTrue(snapshot["freshness"]["stale"])
            self.assertTrue(
                snapshot["freshness"]["sources"]["resources"]["stale"]
            )


class RequestRouteTests(unittest.TestCase):
    def test_allows_query_string_without_changing_exact_route(self):
        self.assertEqual(
            parse_request_route("/api/snapshot?refresh=1"),
            "/api/snapshot",
        )

    def test_rejects_non_origin_form_and_backslash_paths(self):
        for target in (
            "//api/snapshot",
            "https://example.test/api/snapshot",
            "/api\\snapshot",
            "/api/snapshot#fragment",
        ):
            with self.subTest(target=target):
                with self.assertRaises(ValueError):
                    parse_request_route(target)


class CollectorServerTests(unittest.TestCase):
    class StubCollector:
        def snapshot(self):
            return {
                "schemaVersion": SCHEMA_VERSION,
                "source": "test",
            }

    def setUp(self):
        handler = build_handler(self.StubCollector(), ())
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = threading.Thread(
            target=self.server.serve_forever,
            daemon=True,
        )
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, target):
        connection = http.client.HTTPConnection(
            "127.0.0.1",
            self.server.server_port,
            timeout=2,
        )
        try:
            connection.request("GET", target)
            response = connection.getresponse()
            body = json.loads(response.read().decode("utf-8"))
            return response.status, body
        finally:
            connection.close()

    def test_serves_health_and_snapshot_with_query_strings(self):
        health_status, health = self.request("/api/health?probe=1")
        snapshot_status, snapshot = self.request("/api/snapshot?refresh=1")

        self.assertEqual(health_status, 200)
        self.assertEqual(health["status"], "ok")
        self.assertEqual(snapshot_status, 200)
        self.assertEqual(snapshot["source"], "test")

    def test_rejects_trailing_and_ambiguous_slashes(self):
        trailing_status, trailing = self.request("/api/snapshot/")
        ambiguous_status, ambiguous = self.request(
            "https://example.test/api/snapshot"
        )

        self.assertEqual(trailing_status, 404)
        self.assertEqual(trailing["error"], "not found")
        self.assertEqual(ambiguous_status, 400)
        self.assertEqual(ambiguous["error"], "invalid request target")


class CollectorCliTests(unittest.TestCase):
    def test_uses_non_conflicting_default_port(self):
        self.assertEqual(DEFAULT_PORT, 18765)

    def test_snapshot_option_prints_valid_json(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("benchmark_log_collector.py")),
                    "--run-dir",
                    directory,
                    "--snapshot",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

        payload = json.loads(result.stdout)
        self.assertEqual(payload["schemaVersion"], SCHEMA_VERSION)
        self.assertEqual(payload["source"], "jetson-local")

    def test_logs_root_option_tracks_latest_run(self):
        with tempfile.TemporaryDirectory() as directory:
            logs_root = Path(directory)
            run = logs_root / "20260730_120000"
            run.mkdir()
            (run / "yolo.log").write_text(
                "frames=7 fps=17.0 state=HOLD command=HOLD targets=0/0\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("benchmark_log_collector.py")),
                    "--logs-root",
                    directory,
                    "--snapshot",
                ],
                check=True,
                capture_output=True,
                text=True,
            )

        payload = json.loads(result.stdout)
        self.assertEqual(payload["runId"], "20260730_120000")
        self.assertEqual(payload["vision"]["fps"], 17.0)

    def test_http_server_mode_serves_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]

            process = subprocess.Popen(
                [
                    sys.executable,
                    str(Path(__file__).with_name("benchmark_log_collector.py")),
                    "--run-dir",
                    directory,
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(port),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                deadline = time.monotonic() + 5
                while True:
                    try:
                        connection = http.client.HTTPConnection(
                            "127.0.0.1",
                            port,
                            timeout=1,
                        )
                        connection.request("GET", "/api/snapshot?refresh=1")
                        response = connection.getresponse()
                        payload = json.loads(response.read().decode("utf-8"))
                        connection.close()
                        break
                    except OSError:
                        if time.monotonic() >= deadline:
                            self.fail("collector HTTP server did not start")
                        time.sleep(0.05)
            finally:
                process.terminate()
                process.wait(timeout=5)

        self.assertEqual(response.status, 200)
        self.assertEqual(payload["schemaVersion"], SCHEMA_VERSION)
        self.assertEqual(payload["source"], "jetson-local")


if __name__ == "__main__":
    unittest.main()
