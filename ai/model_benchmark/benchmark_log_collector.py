#!/usr/bin/env python3
"""Collect Jetson benchmark logs and expose a local read-only snapshot API."""

from __future__ import annotations

import argparse
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
from typing import Any, Iterable
from urllib.parse import urlparse


SCHEMA_VERSION = "0.1"
DEFAULT_ALLOWED_ORIGINS = (
    "http://localhost:3000",
    "http://127.0.0.1:3000",
)

RAM_PATTERN = re.compile(r"\bRAM\s+(?P<used>\d+)/(?P<total>\d+)MB\b")
GPU_PATTERN = re.compile(r"\bGR3D_FREQ\s+(?P<gpu>\d+)%")
POWER_PATTERN = re.compile(r"\bVDD_IN\s+(?P<power>\d+)mW")
TEMPERATURE_PATTERN = re.compile(
    r"\b(?:gpu|cpu|tj)@(?P<temperature>-?\d+(?:\.\d+)?)C\b",
    re.IGNORECASE,
)
YOLO_PATTERN = re.compile(
    r"frames=(?P<frames>\d+)\s+"
    r"fps=(?P<fps>\d+(?:\.\d+)?)\s+"
    r"state=(?P<state>[A-Z_]+)\s+"
    r"command=(?P<command>[A-Z_]+)\s+"
    r"targets=(?P<targets>\d+)/(?P<objects>\d+)"
)


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def read_tail_lines(path: Path, limit: int = 500) -> list[str]:
    if not path.is_file():
        return []

    with path.open(encoding="utf-8", errors="replace") as file:
        return list(deque(file, maxlen=limit))


def last_matching_line(path: Path, pattern: re.Pattern[str]) -> str | None:
    for line in reversed(read_tail_lines(path)):
        if pattern.search(line):
            return line.strip()
    return None


def parse_tegrastats_line(line: str | None) -> dict[str, int | float | None]:
    result: dict[str, int | float | None] = {
        "ramUsedMb": None,
        "ramTotalMb": None,
        "gpuPercent": None,
        "temperatureC": None,
        "powerMw": None,
    }
    if not line:
        return result

    ram = RAM_PATTERN.search(line)
    gpu = GPU_PATTERN.search(line)
    power = POWER_PATTERN.search(line)
    temperatures = [
        float(match.group("temperature"))
        for match in TEMPERATURE_PATTERN.finditer(line)
    ]

    if ram:
        result["ramUsedMb"] = int(ram.group("used"))
        result["ramTotalMb"] = int(ram.group("total"))
    if gpu:
        result["gpuPercent"] = int(gpu.group("gpu"))
    if power:
        result["powerMw"] = int(power.group("power"))
    if temperatures:
        result["temperatureC"] = max(temperatures)

    return result


def parse_yolo_line(line: str | None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "fps": None,
        "frameCount": None,
        "state": "UNKNOWN",
        "command": "UNKNOWN",
        "targetCount": None,
        "stableObjectCount": None,
    }
    if not line:
        return result

    match = YOLO_PATTERN.search(line)
    if not match:
        return result

    result.update(
        {
            "fps": float(match.group("fps")),
            "frameCount": int(match.group("frames")),
            "state": match.group("state"),
            "command": match.group("command"),
            "targetCount": int(match.group("targets")),
            "stableObjectCount": int(match.group("objects")),
        }
    )
    return result


def load_jsonl_tail(path: Path, limit: int = 120) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in read_tail_lines(path, limit=limit):
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            rows.append(payload)
    return rows


def percentile(values: Iterable[float], ratio: float) -> float | None:
    ordered = sorted(values)
    if not ordered:
        return None
    if len(ordered) == 1:
        return ordered[0]

    position = (len(ordered) - 1) * ratio
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def summarize_audio(rows: list[dict[str, Any]]) -> dict[str, Any]:
    latest = rows[-1] if rows else {}
    inference_values = [
        float(row["inferenceMs"])
        for row in rows
        if isinstance(row.get("inferenceMs"), (int, float))
    ]
    mean_latency = (
        sum(inference_values) / len(inference_values)
        if inference_values
        else None
    )
    p95_latency = percentile(inference_values, 0.95)

    return {
        "model": "YAMNet",
        "selectedScore": latest.get("selectedScore"),
        "selectedClass": latest.get("selectedClass"),
        "topClass": latest.get("topClass"),
        "rms": latest.get("rms"),
        "wouldTrigger": latest.get("wouldTrigger"),
        "latencyMeanMs": round(mean_latency, 3)
        if mean_latency is not None
        else None,
        "latencyP95Ms": round(p95_latency, 3)
        if p95_latency is not None
        else None,
        "sampleCount": len(inference_values),
    }


def load_recent_events(event_dir: Path | None, limit: int = 12) -> list[dict[str, Any]]:
    if event_dir is None or not event_dir.is_dir():
        return []

    candidates = sorted(
        event_dir.glob("*.trigger.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    events: list[dict[str, Any]] = []
    for path in candidates[:limit]:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict):
            continue
        events.append(
            {
                "eventId": payload.get("eventId", path.name.split(".", 1)[0]),
                "eventType": payload.get("type", payload.get("eventType")),
                "observedAt": payload.get(
                    "occurredAt",
                    payload.get("detectedAt"),
                ),
                "confidence": payload.get("confidence", payload.get("score")),
                "className": payload.get("className"),
            }
        )
    return events


def load_benchmark_results(
    results_dir: Path | None,
    limit: int = 24,
) -> list[dict[str, Any]]:
    if results_dir is None or not results_dir.is_dir():
        return []

    candidates = sorted(
        results_dir.glob("**/summary.json"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    results: list[dict[str, Any]] = []
    for path in candidates[:limit]:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict):
            continue
        model = payload.get("model")
        metrics = payload.get("metrics")
        if not isinstance(model, dict) or not isinstance(metrics, dict):
            continue
        results.append(
            {
                "runId": payload.get("runId"),
                "createdAt": payload.get("createdAt"),
                "component": payload.get("component", "vision"),
                "model": model.get("name"),
                "runtime": model.get("runtime"),
                "dataset": (
                    payload.get("dataset", {}).get("name")
                    if isinstance(payload.get("dataset"), dict)
                    else None
                ),
                "metrics": metrics,
            }
        )
    return results


@dataclass(frozen=True)
class CollectorPaths:
    run_dir: Path
    event_dir: Path | None = None
    results_dir: Path | None = None

    @property
    def resources(self) -> Path:
        return self.run_dir / "resources.log"

    @property
    def yolo(self) -> Path:
        return self.run_dir / "yolo.log"

    @property
    def yamnet_diagnostics(self) -> Path:
        candidates = (
            self.run_dir / "yamnet_diagnostics.jsonl",
            self.run_dir / "yamnet.jsonl",
            self.run_dir / "diagnostics.jsonl",
        )
        return next((path for path in candidates if path.is_file()), candidates[0])


class BenchmarkCollector:
    def __init__(self, paths: CollectorPaths) -> None:
        self.paths = paths

    def snapshot(self) -> dict[str, Any]:
        resource_line = last_matching_line(self.paths.resources, RAM_PATTERN)
        yolo_line = last_matching_line(self.paths.yolo, YOLO_PATTERN)
        audio_rows = load_jsonl_tail(self.paths.yamnet_diagnostics)

        return {
            "schemaVersion": SCHEMA_VERSION,
            "collectedAt": utc_now(),
            "source": "jetson-local",
            "runId": self.paths.run_dir.name,
            "runDirectory": str(self.paths.run_dir),
            "system": parse_tegrastats_line(resource_line),
            "vision": parse_yolo_line(yolo_line),
            "audio": summarize_audio(audio_rows),
            "events": load_recent_events(self.paths.event_dir),
            "comparisons": load_benchmark_results(self.paths.results_dir),
        }


def build_handler(
    collector: BenchmarkCollector,
    allowed_origins: tuple[str, ...],
) -> type[BaseHTTPRequestHandler]:
    class SnapshotHandler(BaseHTTPRequestHandler):
        server_version = "WJBenchmarkCollector/0.1"

        def do_GET(self) -> None:  # noqa: N802
            route = urlparse(self.path).path
            if route == "/api/health":
                self.send_json({"status": "ok", "schemaVersion": SCHEMA_VERSION})
                return
            if route == "/api/snapshot":
                self.send_json(collector.snapshot())
                return
            self.send_json({"error": "not found"}, status=404)

        def do_OPTIONS(self) -> None:  # noqa: N802
            self.send_response(204)
            self.add_cors_headers()
            self.end_headers()

        def send_json(self, payload: dict[str, Any], status: int = 200) -> None:
            body = json.dumps(
                payload,
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.add_cors_headers()
            self.end_headers()
            self.wfile.write(body)

        def add_cors_headers(self) -> None:
            origin = self.headers.get("Origin")
            if origin in allowed_origins:
                self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Vary", "Origin")
                self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
                self.send_header("Access-Control-Allow-Headers", "Content-Type")

        def log_message(self, format_string: str, *args: object) -> None:
            print(
                f"[benchmark-api] {self.address_string()} "
                f"{format_string % args}"
            )

    return SnapshotHandler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Serve a read-only local snapshot of Jetson AI logs.",
    )
    parser.add_argument(
        "--run-dir",
        type=Path,
        required=True,
        help="Directory containing resources.log, yolo.log and YAMNet JSONL.",
    )
    parser.add_argument(
        "--event-dir",
        type=Path,
        help="Optional directory containing *.trigger.json event metadata.",
    )
    parser.add_argument(
        "--results-dir",
        type=Path,
        help="Optional directory containing benchmark */summary.json files.",
    )
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument(
        "--allow-lan",
        action="store_true",
        help="Required when binding to a non-loopback interface.",
    )
    parser.add_argument(
        "--origin",
        action="append",
        dest="origins",
        help="Allowed dashboard origin. Can be supplied multiple times.",
    )
    parser.add_argument(
        "--snapshot",
        action="store_true",
        help="Print one JSON snapshot instead of starting the HTTP server.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_dir = args.run_dir.expanduser().resolve()
    event_dir = (
        args.event_dir.expanduser().resolve()
        if args.event_dir is not None
        else None
    )
    results_dir = (
        args.results_dir.expanduser().resolve()
        if args.results_dir is not None
        else None
    )
    if not run_dir.is_dir():
        raise SystemExit(f"run directory does not exist: {run_dir}")
    if args.host not in {"127.0.0.1", "::1", "localhost"} and not args.allow_lan:
        raise SystemExit("non-loopback bind requires --allow-lan")

    collector = BenchmarkCollector(
        CollectorPaths(
            run_dir=run_dir,
            event_dir=event_dir,
            results_dir=results_dir,
        )
    )
    if args.snapshot:
        print(json.dumps(collector.snapshot(), ensure_ascii=False, indent=2))
        return 0

    origins = tuple(args.origins or DEFAULT_ALLOWED_ORIGINS)
    server = ThreadingHTTPServer(
        (args.host, args.port),
        build_handler(collector, origins),
    )
    print(f"Benchmark snapshot API: http://{args.host}:{args.port}/api/snapshot")
    print(f"Run directory: {run_dir}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
