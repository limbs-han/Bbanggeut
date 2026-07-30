#!/usr/bin/env python3
"""Run one local YOLO model against a manifest-backed benchmark dataset."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import statistics
import time
from typing import Any, Iterable

from benchmark_dataset import load_dataset, validate_dataset


SCHEMA_VERSION = "0.1"


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


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


def infer_runtime(model_path: Path) -> str:
    suffix = model_path.suffix.lower()
    if suffix == ".engine":
        return "tensorrt"
    if suffix in {".onnx"}:
        return "onnx"
    if suffix in {".pt", ".pth"}:
        return "pytorch"
    return suffix.lstrip(".") or "unknown"


@dataclass(frozen=True)
class FrameMeasurement:
    sample_id: str
    repeat: int
    frame_index: int
    wall_ms: float
    preprocess_ms: float | None
    inference_ms: float | None
    postprocess_ms: float | None
    detection_count: int
    class_counts: dict[str, int]

    def as_json(self, run_id: str, model: str, runtime: str) -> dict[str, Any]:
        return {
            "schemaVersion": SCHEMA_VERSION,
            "observedAt": utc_now(),
            "runId": run_id,
            "component": "vision",
            "model": model,
            "runtime": runtime,
            "sampleId": self.sample_id,
            "repeat": self.repeat,
            "frameIndex": self.frame_index,
            "metrics": {
                "wallMs": round(self.wall_ms, 3),
                "preprocessMs": rounded(self.preprocess_ms),
                "inferenceMs": rounded(self.inference_ms),
                "postprocessMs": rounded(self.postprocess_ms),
                "detectionCount": self.detection_count,
                "classCounts": self.class_counts,
            },
        }


def rounded(value: float | None) -> float | None:
    return round(value, 3) if value is not None else None


def summarize_measurements(
    measurements: list[FrameMeasurement],
    *,
    run_id: str,
    model_name: str,
    runtime: str,
    model_path: Path,
    dataset_name: str,
    warmup_frames: int,
    repeats: int,
    imgsz: int,
    device: str,
) -> dict[str, Any]:
    wall_values = [row.wall_ms for row in measurements]
    inference_values = [
        row.inference_ms
        for row in measurements
        if row.inference_ms is not None
    ]
    total_detections = sum(row.detection_count for row in measurements)
    class_counts: dict[str, int] = {}
    for row in measurements:
        for class_name, count in row.class_counts.items():
            class_counts[class_name] = class_counts.get(class_name, 0) + count

    mean_wall = statistics.fmean(wall_values) if wall_values else None
    return {
        "schemaVersion": SCHEMA_VERSION,
        "runId": run_id,
        "createdAt": utc_now(),
        "model": {
            "name": model_name,
            "path": str(model_path),
            "runtime": runtime,
            "sizeBytes": model_path.stat().st_size,
        },
        "dataset": {
            "name": dataset_name,
            "sampleCount": len({row.sample_id for row in measurements}),
        },
        "configuration": {
            "device": device,
            "imgsz": imgsz,
            "warmupFrames": warmup_frames,
            "repeats": repeats,
        },
        "environment": {
            "python": platform.python_version(),
            "platform": platform.platform(),
        },
        "metrics": {
            "measuredFrames": len(measurements),
            "fps": rounded(1000.0 / mean_wall)
            if mean_wall is not None and mean_wall > 0
            else None,
            "wallMeanMs": rounded(mean_wall),
            "wallP95Ms": rounded(percentile(wall_values, 0.95)),
            "inferenceMeanMs": rounded(
                statistics.fmean(inference_values) if inference_values else None
            ),
            "inferenceP95Ms": rounded(percentile(inference_values, 0.95)),
            "totalDetections": total_detections,
            "classCounts": dict(sorted(class_counts.items())),
        },
        "accuracy": {
            "status": "not-computed",
            "reason": (
                "Dataset manifest has scene labels only. Add frame-level boxes "
                "before computing precision, recall or mAP."
            ),
        },
    }


def extract_class_counts(result: Any) -> tuple[int, dict[str, int]]:
    boxes = getattr(result, "boxes", None)
    if boxes is None:
        return 0, {}
    classes = getattr(boxes, "cls", None)
    if classes is None:
        return len(boxes), {}

    values = classes.detach().cpu().tolist()
    names = getattr(result, "names", {})
    counts: dict[str, int] = {}
    for value in values:
        index = int(value)
        name = str(names.get(index, index)) if isinstance(names, dict) else str(index)
        counts[name] = counts.get(name, 0) + 1
    return len(values), counts


def speed_value(result: Any, key: str) -> float | None:
    speed = getattr(result, "speed", None)
    if not isinstance(speed, dict):
        return None
    value = speed.get(key)
    return float(value) if isinstance(value, (int, float)) else None


def run_sample(
    model: Any,
    *,
    sample_id: str,
    media_path: Path,
    repeat: int,
    device: str,
    imgsz: int,
    warmup_frames: int,
    max_frames: int,
) -> list[FrameMeasurement]:
    results = model.predict(
        source=str(media_path),
        stream=True,
        verbose=False,
        device=device,
        imgsz=imgsz,
    )
    measurements: list[FrameMeasurement] = []
    previous = time.perf_counter()
    for frame_index, result in enumerate(results):
        now = time.perf_counter()
        wall_ms = (now - previous) * 1000.0
        previous = now
        if frame_index < warmup_frames:
            continue

        detection_count, class_counts = extract_class_counts(result)
        measurements.append(
            FrameMeasurement(
                sample_id=sample_id,
                repeat=repeat,
                frame_index=frame_index,
                wall_ms=wall_ms,
                preprocess_ms=speed_value(result, "preprocess"),
                inference_ms=speed_value(result, "inference"),
                postprocess_ms=speed_value(result, "postprocess"),
                detection_count=detection_count,
                class_counts=class_counts,
            )
        )
        if max_frames and len(measurements) >= max_frames:
            break
    return measurements


def write_jsonl(
    path: Path,
    measurements: list[FrameMeasurement],
    *,
    run_id: str,
    model_name: str,
    runtime: str,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as file:
        for row in measurements:
            file.write(
                json.dumps(
                    row.as_json(run_id, model_name, runtime),
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
                + "\n"
            )
    temporary.replace(path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Benchmark an explicitly provided local YOLO model without "
            "downloading weights."
        )
    )
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--model-name")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--device", default="0")
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--warmup-frames", type=int, default=30)
    parser.add_argument("--max-frames", type=int, default=300)
    parser.add_argument("--repeats", type=int, default=3)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    dataset_root = args.dataset_root.expanduser().resolve()
    model_path = args.model.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()

    errors = validate_dataset(dataset_root)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    if not model_path.is_file():
        print(f"ERROR: model does not exist: {model_path}")
        return 1
    if args.imgsz < 1 or args.warmup_frames < 0 or args.max_frames < 0:
        print("ERROR: invalid frame or image-size configuration")
        return 1
    if args.repeats < 1:
        print("ERROR: repeats must be positive")
        return 1

    try:
        from ultralytics import YOLO
    except ImportError:
        print("ERROR: ultralytics is not installed in this Python environment")
        return 1

    dataset = load_dataset(dataset_root)
    run_id = datetime.now(timezone.utc).strftime("vision-%Y%m%dT%H%M%SZ")
    model_name = args.model_name or model_path.stem
    runtime = infer_runtime(model_path)
    model = YOLO(str(model_path))
    measurements: list[FrameMeasurement] = []

    for repeat in range(1, args.repeats + 1):
        for sample in dataset["samples"]:
            sample_id = sample["sampleId"]
            media_path = (dataset_root / sample["media"]).resolve()
            print(
                f"[{repeat}/{args.repeats}] "
                f"model={model_name} sample={sample_id}"
            )
            measurements.extend(
                run_sample(
                    model,
                    sample_id=sample_id,
                    media_path=media_path,
                    repeat=repeat,
                    device=args.device,
                    imgsz=args.imgsz,
                    warmup_frames=args.warmup_frames,
                    max_frames=args.max_frames,
                )
            )

    output_dir.mkdir(parents=True, exist_ok=True)
    write_jsonl(
        output_dir / "frames.jsonl",
        measurements,
        run_id=run_id,
        model_name=model_name,
        runtime=runtime,
    )
    summary = summarize_measurements(
        measurements,
        run_id=run_id,
        model_name=model_name,
        runtime=runtime,
        model_path=model_path,
        dataset_name=str(dataset.get("name")),
        warmup_frames=args.warmup_frames,
        repeats=args.repeats,
        imgsz=args.imgsz,
        device=args.device,
    )
    (output_dir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"PASS: wrote {len(measurements)} frame measurements to {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
