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
from typing import Any, Callable, Iterable

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


def normalize_class_ids(class_ids: Iterable[int]) -> list[int] | None:
    return sorted(set(class_ids)) or None


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


def build_progress_payload(
    *,
    run_id: str,
    status: str,
    model_name: str,
    runtime: str,
    dataset_name: str,
    completed_frames: int,
    total_frames: int | None,
    completed_tasks: int,
    total_tasks: int,
    repeat: int | None = None,
    sample_id: str | None = None,
    error: str | None = None,
) -> dict[str, Any]:
    if status == "completed":
        percent = 100.0
    elif total_frames is not None and total_frames > 0:
        percent = min(100.0, completed_frames / total_frames * 100.0)
    elif total_tasks > 0:
        percent = min(100.0, completed_tasks / total_tasks * 100.0)
    else:
        percent = None

    current = (
        {"repeat": repeat, "sampleId": sample_id}
        if repeat is not None or sample_id is not None
        else None
    )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "runId": run_id,
        "updatedAt": utc_now(),
        "status": status,
        "component": "vision",
        "model": model_name,
        "runtime": runtime,
        "dataset": dataset_name,
        "progress": {
            "completedFrames": completed_frames,
            "totalFrames": total_frames,
            "completedTasks": completed_tasks,
            "totalTasks": total_tasks,
            "percent": rounded(percent),
        },
        "current": current,
        "error": error,
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


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
    confidence: float,
    iou: float,
    class_ids: list[int] | None,
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
            "confidence": confidence,
            "iou": iou,
            "classIds": class_ids,
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
    confidence: float,
    iou: float,
    class_ids: list[int] | None,
    progress_callback: Callable[[int], None] | None = None,
) -> list[FrameMeasurement]:
    predict_options: dict[str, Any] = {
        "source": str(media_path),
        "stream": True,
        "verbose": False,
        "device": device,
        "imgsz": imgsz,
        "conf": confidence,
        "iou": iou,
    }
    if class_ids:
        predict_options["classes"] = class_ids
    results = model.predict(**predict_options)
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
        if progress_callback is not None and len(measurements) % 25 == 0:
            progress_callback(len(measurements))
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
    parser.add_argument(
        "--confidence",
        "--conf",
        dest="confidence",
        type=float,
        default=0.25,
    )
    parser.add_argument("--iou", type=float, default=0.7)
    parser.add_argument(
        "--class-id",
        action="append",
        dest="class_ids",
        type=int,
        default=[],
        help=(
            "Limit inference to this class ID. Repeat the option for multiple "
            "classes; omit it to evaluate every model class."
        ),
    )
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
    if not 0.0 <= args.confidence <= 1.0:
        print("ERROR: confidence must be between 0 and 1")
        return 1
    if not 0.0 <= args.iou <= 1.0:
        print("ERROR: IoU must be between 0 and 1")
        return 1
    if any(class_id < 0 for class_id in args.class_ids):
        print("ERROR: class IDs must be non-negative")
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
    class_ids = normalize_class_ids(args.class_ids)
    model = YOLO(str(model_path))
    measurements: list[FrameMeasurement] = []
    output_dir.mkdir(parents=True, exist_ok=True)
    progress_path = output_dir / "progress.json"
    dataset_name = str(dataset.get("name"))
    total_tasks = len(dataset["samples"]) * args.repeats
    total_frames = (
        total_tasks * args.max_frames
        if args.max_frames > 0
        else None
    )
    completed_tasks = 0

    def persist_progress(
        status: str,
        *,
        completed_frames: int,
        repeat: int | None = None,
        sample_id: str | None = None,
        error: str | None = None,
    ) -> None:
        effective_total_frames = (
            completed_frames
            if status == "completed"
            else total_frames
        )
        write_json(
            progress_path,
            build_progress_payload(
                run_id=run_id,
                status=status,
                model_name=model_name,
                runtime=runtime,
                dataset_name=dataset_name,
                completed_frames=completed_frames,
                total_frames=effective_total_frames,
                completed_tasks=completed_tasks,
                total_tasks=total_tasks,
                repeat=repeat,
                sample_id=sample_id,
                error=error,
            ),
        )

    persist_progress("running", completed_frames=0)
    try:
        for repeat in range(1, args.repeats + 1):
            for sample in dataset["samples"]:
                sample_id = sample["sampleId"]
                media_path = (dataset_root / sample["media"]).resolve()
                print(
                    f"[{repeat}/{args.repeats}] "
                    f"model={model_name} sample={sample_id}"
                )
                completed_before_sample = len(measurements)

                def update_sample_progress(sample_frames: int) -> None:
                    persist_progress(
                        "running",
                        completed_frames=completed_before_sample + sample_frames,
                        repeat=repeat,
                        sample_id=sample_id,
                    )

                sample_measurements = run_sample(
                    model,
                    sample_id=sample_id,
                    media_path=media_path,
                    repeat=repeat,
                    device=args.device,
                    imgsz=args.imgsz,
                    warmup_frames=args.warmup_frames,
                    max_frames=args.max_frames,
                    confidence=args.confidence,
                    iou=args.iou,
                    class_ids=class_ids,
                    progress_callback=update_sample_progress,
                )
                measurements.extend(sample_measurements)
                completed_tasks += 1
                persist_progress(
                    "running",
                    completed_frames=len(measurements),
                    repeat=repeat,
                    sample_id=sample_id,
                )
    except Exception as error:
        persist_progress(
            "failed",
            completed_frames=len(measurements),
            error=str(error),
        )
        raise

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
        dataset_name=dataset_name,
        warmup_frames=args.warmup_frames,
        repeats=args.repeats,
        imgsz=args.imgsz,
        device=args.device,
        confidence=args.confidence,
        iou=args.iou,
        class_ids=class_ids,
    )
    write_json(
        output_dir / "summary.json",
        summary,
    )
    persist_progress(
        "completed",
        completed_frames=len(measurements),
    )
    print(f"PASS: wrote {len(measurements)} frame measurements to {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
