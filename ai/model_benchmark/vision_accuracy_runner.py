#!/usr/bin/env python3
"""Evaluate local YOLO detection models against frame-level YOLO labels."""

from __future__ import annotations

import argparse
from collections import defaultdict
from contextlib import AbstractContextManager
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import time
from typing import Any, Iterable

from benchmark_log_collector import parse_tegrastats_line
from vision_benchmark_runner import infer_runtime, percentile, rounded, write_json


SCHEMA_VERSION = "0.2"
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass(frozen=True)
class DetectionBox:
    class_id: int
    x1: float
    y1: float
    x2: float
    y2: float
    confidence: float = 1.0


@dataclass(frozen=True)
class MatchCounts:
    true_positive: int = 0
    false_positive: int = 0
    false_negative: int = 0

    def __add__(self, other: "MatchCounts") -> "MatchCounts":
        return MatchCounts(
            self.true_positive + other.true_positive,
            self.false_positive + other.false_positive,
            self.false_negative + other.false_negative,
        )


@dataclass(frozen=True)
class FrameEvaluation:
    image: str
    scenario: str
    counts: MatchCounts
    ground_truth_count: int
    prediction_count: int
    wall_ms: float
    preprocess_ms: float | None
    inference_ms: float | None
    postprocess_ms: float | None

    def as_json(self) -> dict[str, Any]:
        return {
            "image": self.image,
            "scenario": self.scenario,
            "groundTruthCount": self.ground_truth_count,
            "predictionCount": self.prediction_count,
            "truePositive": self.counts.true_positive,
            "falsePositive": self.counts.false_positive,
            "falseNegative": self.counts.false_negative,
            "wallMs": rounded(self.wall_ms),
            "preprocessMs": rounded(self.preprocess_ms),
            "inferenceMs": rounded(self.inference_ms),
            "postprocessMs": rounded(self.postprocess_ms),
        }


def box_iou(first: DetectionBox, second: DetectionBox) -> float:
    left = max(first.x1, second.x1)
    top = max(first.y1, second.y1)
    right = min(first.x2, second.x2)
    bottom = min(first.y2, second.y2)
    intersection = max(0.0, right - left) * max(0.0, bottom - top)
    first_area = max(0.0, first.x2 - first.x1) * max(
        0.0, first.y2 - first.y1
    )
    second_area = max(0.0, second.x2 - second.x1) * max(
        0.0, second.y2 - second.y1
    )
    union = first_area + second_area - intersection
    return intersection / union if union > 0 else 0.0


def match_boxes(
    ground_truth: Iterable[DetectionBox],
    predictions: Iterable[DetectionBox],
    *,
    iou_threshold: float,
) -> MatchCounts:
    expected = list(ground_truth)
    observed = sorted(
        predictions,
        key=lambda box: box.confidence,
        reverse=True,
    )
    unmatched = set(range(len(expected)))
    true_positive = 0
    false_positive = 0

    for prediction in observed:
        candidates = [
            (box_iou(prediction, expected[index]), index)
            for index in unmatched
            if expected[index].class_id == prediction.class_id
        ]
        best_iou, best_index = max(candidates, default=(0.0, -1))
        if best_iou >= iou_threshold:
            true_positive += 1
            unmatched.remove(best_index)
        else:
            false_positive += 1

    return MatchCounts(
        true_positive=true_positive,
        false_positive=false_positive,
        false_negative=len(unmatched),
    )


def metrics_from_counts(counts: MatchCounts) -> dict[str, float | int]:
    precision_denominator = counts.true_positive + counts.false_positive
    recall_denominator = counts.true_positive + counts.false_negative
    precision = (
        counts.true_positive / precision_denominator
        if precision_denominator
        else 1.0
    )
    recall = (
        counts.true_positive / recall_denominator
        if recall_denominator
        else 1.0
    )
    f1 = (
        2 * precision * recall / (precision + recall)
        if precision + recall
        else 0.0
    )
    return {
        "truePositive": counts.true_positive,
        "falsePositive": counts.false_positive,
        "falseNegative": counts.false_negative,
        "precision": round(precision, 6),
        "recall": round(recall, 6),
        "f1": round(f1, 6),
    }


def scenario_from_stem(stem: str) -> str:
    source = stem.split("__", 1)[0]
    office_at = source.find("office-")
    return source[office_at:] if office_at >= 0 else source


def load_yolo_labels(path: Path) -> list[DetectionBox]:
    boxes: list[DetectionBox] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8-sig").splitlines(),
        1,
    ):
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) != 5:
            raise ValueError(f"{path}:{line_number}: expected five fields")
        class_id = int(parts[0])
        center_x, center_y, width, height = map(float, parts[1:])
        if (
            class_id < 0
            or any(
                not math.isfinite(value) or value < 0.0 or value > 1.0
                for value in (center_x, center_y, width, height)
            )
            or width <= 0.0
            or height <= 0.0
        ):
            raise ValueError(f"{path}:{line_number}: invalid YOLO box")
        boxes.append(
            DetectionBox(
                class_id=class_id,
                x1=max(0.0, center_x - width / 2),
                y1=max(0.0, center_y - height / 2),
                x2=min(1.0, center_x + width / 2),
                y2=min(1.0, center_y + height / 2),
            )
        )
    return boxes


def extract_predictions(result: Any) -> list[DetectionBox]:
    boxes = getattr(result, "boxes", None)
    if boxes is None or len(boxes) == 0:
        return []
    coordinates = boxes.xyxyn.detach().cpu().tolist()
    classes = boxes.cls.detach().cpu().tolist()
    confidences = boxes.conf.detach().cpu().tolist()
    return [
        DetectionBox(
            class_id=int(class_id),
            x1=float(values[0]),
            y1=float(values[1]),
            x2=float(values[2]),
            y2=float(values[3]),
            confidence=float(confidence),
        )
        for values, class_id, confidence in zip(
            coordinates,
            classes,
            confidences,
            strict=True,
        )
    ]


def speed_value(result: Any, key: str) -> float | None:
    speed = getattr(result, "speed", None)
    if not isinstance(speed, dict):
        return None
    value = speed.get(key)
    return float(value) if isinstance(value, (int, float)) else None


def discover_image_label_pairs(
    dataset_root: Path,
) -> list[tuple[Path, Path]]:
    image_root = dataset_root / "images" / "test"
    label_root = dataset_root / "labels" / "test"
    if not image_root.is_dir() or not label_root.is_dir():
        raise ValueError("dataset must contain images/test and labels/test")
    images = sorted(
        path
        for path in image_root.iterdir()
        if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
    )
    if not images:
        raise ValueError("dataset has no test images")
    pairs: list[tuple[Path, Path]] = []
    image_stems = {path.stem for path in images}
    label_stems = {path.stem for path in label_root.glob("*.txt")}
    if image_stems != label_stems:
        missing_labels = sorted(image_stems - label_stems)
        missing_images = sorted(label_stems - image_stems)
        raise ValueError(
            "image/label stems differ: "
            f"missingLabels={missing_labels[:5]} "
            f"missingImages={missing_images[:5]}"
        )
    for image in images:
        pairs.append((image, label_root / f"{image.stem}.txt"))
    return pairs


def dataset_fingerprint(
    dataset_root: Path,
    pairs: Iterable[tuple[Path, Path]],
) -> tuple[str, int]:
    digest = hashlib.sha256()
    image_hashes: list[str] = []
    for image, label in pairs:
        relative_image = image.relative_to(dataset_root).as_posix()
        relative_label = label.relative_to(dataset_root).as_posix()
        image_hash = sha256_file(image)
        label_hash = sha256_file(label)
        image_hashes.append(image_hash)
        digest.update(
            f"{relative_image}\0{image_hash}\0{relative_label}\0{label_hash}\n".encode(
                "utf-8"
            )
        )
    duplicate_count = len(image_hashes) - len(set(image_hashes))
    return digest.hexdigest(), duplicate_count


def standard_metrics(result: Any) -> dict[str, float | int | None]:
    box = getattr(result, "box", None)
    if box is None:
        raise ValueError("Ultralytics validation did not return box metrics")
    return {
        "precision": rounded(float(box.mp)),
        "recall": rounded(float(box.mr)),
        "mAP50": rounded(float(box.map50)),
        "mAP50_95": rounded(float(box.map)),
    }


def write_runtime_data_yaml(dataset_root: Path, output_dir: Path) -> Path:
    path = output_dir / "evaluation-data.yaml"
    root = json.dumps(dataset_root.as_posix(), ensure_ascii=False)
    path.write_text(
        "\n".join(
            (
                f"path: {root}",
                "train: images/test",
                "val: images/test",
                "test: images/test",
                "names:",
                "  0: person",
                "",
            )
        ),
        encoding="utf-8",
    )
    return path


class TegrastatsMonitor(AbstractContextManager["TegrastatsMonitor"]):
    def __init__(self, output_path: Path, interval_ms: int = 1000):
        self.output_path = output_path
        self.interval_ms = interval_ms
        self.process: subprocess.Popen[str] | None = None
        self.file: Any | None = None

    def __enter__(self) -> "TegrastatsMonitor":
        executable = shutil.which("tegrastats")
        if executable is None:
            return self
        self.file = self.output_path.open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            [executable, "--interval", str(self.interval_ms)],
            stdout=self.file,
            stderr=subprocess.STDOUT,
            text=True,
        )
        return self

    def __exit__(self, *args: object) -> None:
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.file is not None:
            self.file.close()

    @property
    def collected(self) -> bool:
        return self.process is not None


def summarize_resources(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {"status": "not-collected", "sampleCount": 0}
    rows = [
        parse_tegrastats_line(line)
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
        if line.strip()
    ]
    fields = ("gpuPercent", "ramUsedMb", "temperatureC", "powerMw")
    summary: dict[str, Any] = {
        "status": "computed" if rows else "not-collected",
        "sampleCount": len(rows),
    }
    for field in fields:
        values = [
            float(row[field])
            for row in rows
            if isinstance(row.get(field), (int, float))
        ]
        summary[f"{field}Mean"] = rounded(
            statistics.fmean(values) if values else None
        )
        summary[f"{field}Max"] = rounded(max(values) if values else None)
    return summary


def command_output(command: list[str]) -> str | None:
    executable = shutil.which(command[0])
    if executable is None:
        return None
    try:
        result = subprocess.run(
            [executable, *command[1:]],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    output = (result.stdout + result.stderr).strip()
    return output or None


def build_progress(
    *,
    run_id: str,
    model_name: str,
    dataset_name: str,
    status: str,
    stage: str,
    completed: int,
    total: int,
    trial_index: int = 1,
    trial_count: int = 1,
    execution_order: int = 1,
    comparison_id: str | None = None,
    current_image: str | None = None,
    error: str | None = None,
) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "runId": run_id,
        "updatedAt": utc_now(),
        "status": status,
        "component": "vision",
        "model": model_name,
        "runtime": None,
        "dataset": dataset_name,
        "progress": {
            "completedFrames": completed,
            "totalFrames": total,
            "completedTasks": completed,
            "totalTasks": total,
            "percent": rounded(completed / total * 100.0) if total else None,
            "stage": stage,
        },
        "comparison": {
            "id": comparison_id,
            "trialIndex": trial_index,
            "trialCount": trial_count,
            "executionOrder": execution_order,
        },
        "current": {
            "sampleId": current_image,
            "repeat": trial_index,
        },
        "error": error,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Evaluate one explicit local YOLO model against YOLO test labels."
        )
    )
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--model-name")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--device", default="0")
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--batch", type=int, default=1)
    parser.add_argument("--warmup-frames", type=int, default=10)
    parser.add_argument("--map-confidence", type=float, default=0.001)
    parser.add_argument("--operating-confidence", type=float, default=0.25)
    parser.add_argument("--nms-iou", type=float, default=0.7)
    parser.add_argument("--match-iou", type=float, default=0.5)
    parser.add_argument("--class-id", type=int, default=0)
    parser.add_argument("--comparison-id")
    parser.add_argument("--trial-index", type=int, default=1)
    parser.add_argument("--trial-count", type=int, default=1)
    parser.add_argument("--execution-order", type=int, default=1)
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> list[str]:
    errors: list[str] = []
    if args.imgsz < 1 or args.batch < 1 or args.warmup_frames < 0:
        errors.append("image size, batch and warm-up values are invalid")
    for name in (
        "map_confidence",
        "operating_confidence",
        "nms_iou",
        "match_iou",
    ):
        value = getattr(args, name)
        if not 0.0 <= value <= 1.0:
            errors.append(f"{name} must be between zero and one")
    if args.class_id < 0:
        errors.append("class ID must be non-negative")
    if args.trial_count < 1:
        errors.append("trial count must be positive")
    if not 1 <= args.trial_index <= args.trial_count:
        errors.append("trial index must be within the trial count")
    if args.execution_order < 1:
        errors.append("execution order must be positive")
    return errors


def main() -> int:
    args = parse_args()
    argument_errors = validate_args(args)
    for error in argument_errors:
        print(f"ERROR: {error}")
    if argument_errors:
        return 1

    dataset_root = args.dataset_root.expanduser().resolve()
    model_path = args.model.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    if not model_path.is_file():
        print(f"ERROR: model does not exist: {model_path}")
        return 1
    try:
        pairs = discover_image_label_pairs(dataset_root)
        labels = {
            image.stem: load_yolo_labels(label)
            for image, label in pairs
        }
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}")
        return 1

    try:
        import torch
        import ultralytics
        from ultralytics import YOLO
    except ImportError:
        print("ERROR: ultralytics is not installed")
        return 1

    output_dir.mkdir(parents=True, exist_ok=True)
    runtime_data = write_runtime_data_yaml(dataset_root, output_dir)
    run_id = datetime.now(timezone.utc).strftime("vision-accuracy-%Y%m%dT%H%M%SZ")
    model_name = args.model_name or model_path.stem
    dataset_name = dataset_root.name
    runtime = infer_runtime(model_path)
    progress_path = output_dir / "progress.json"
    resources_path = output_dir / "resources.log"
    total_progress = len(pairs) * 2

    def persist_progress(
        status: str,
        stage: str,
        completed: int,
        current_image: str | None = None,
        error: str | None = None,
    ) -> None:
        payload = build_progress(
            run_id=run_id,
            model_name=model_name,
            dataset_name=dataset_name,
            status=status,
            stage=stage,
            completed=completed,
            total=total_progress,
            trial_index=args.trial_index,
            trial_count=args.trial_count,
            execution_order=args.execution_order,
            comparison_id=args.comparison_id,
            current_image=current_image,
            error=error,
        )
        payload["runtime"] = runtime
        write_json(progress_path, payload)

    model = YOLO(str(model_path))
    evaluations: list[FrameEvaluation] = []
    persist_progress("running", "standard-map", 0)

    try:
        with TegrastatsMonitor(resources_path):
            validation = model.val(
                data=str(runtime_data),
                split="test",
                device=args.device,
                imgsz=args.imgsz,
                batch=args.batch,
                conf=args.map_confidence,
                iou=args.nms_iou,
                classes=[args.class_id],
                workers=0,
                plots=True,
                project=str(output_dir / "artifacts"),
                name="standard-map",
                exist_ok=True,
                verbose=False,
            )
            map_metrics = standard_metrics(validation)
            persist_progress("running", "operating-point", len(pairs))

            predict_options = {
                "device": args.device,
                "imgsz": args.imgsz,
                "conf": args.operating_confidence,
                "iou": args.nms_iou,
                "classes": [args.class_id],
                "verbose": False,
            }
            for _ in range(args.warmup_frames):
                model.predict(source=str(pairs[0][0]), **predict_options)

            for index, (image_path, _) in enumerate(pairs, 1):
                started = time.perf_counter()
                results = model.predict(source=str(image_path), **predict_options)
                wall_ms = (time.perf_counter() - started) * 1000.0
                result = results[0]
                predictions = extract_predictions(result)
                ground_truth = labels[image_path.stem]
                counts = match_boxes(
                    ground_truth,
                    predictions,
                    iou_threshold=args.match_iou,
                )
                evaluations.append(
                    FrameEvaluation(
                        image=image_path.name,
                        scenario=scenario_from_stem(image_path.stem),
                        counts=counts,
                        ground_truth_count=len(ground_truth),
                        prediction_count=len(predictions),
                        wall_ms=wall_ms,
                        preprocess_ms=speed_value(result, "preprocess"),
                        inference_ms=speed_value(result, "inference"),
                        postprocess_ms=speed_value(result, "postprocess"),
                    )
                )
                if index % 10 == 0 or index == len(pairs):
                    persist_progress(
                        "running",
                        "operating-point",
                        len(pairs) + index,
                        image_path.name,
                    )
    except Exception as error:
        persist_progress(
            "failed",
            "evaluation",
            len(pairs) + len(evaluations),
            error=str(error),
        )
        raise

    total_counts = MatchCounts()
    scenario_counts: dict[str, MatchCounts] = defaultdict(MatchCounts)
    scenario_images: dict[str, int] = defaultdict(int)
    for row in evaluations:
        total_counts += row.counts
        scenario_counts[row.scenario] += row.counts
        scenario_images[row.scenario] += 1

    wall_values = [row.wall_ms for row in evaluations]
    inference_values = [
        row.inference_ms
        for row in evaluations
        if row.inference_ms is not None
    ]
    mean_wall = statistics.fmean(wall_values)
    fingerprint, duplicate_count = dataset_fingerprint(dataset_root, pairs)
    empty_count = sum(1 for boxes in labels.values() if not boxes)
    box_count = sum(len(boxes) for boxes in labels.values())
    operating = metrics_from_counts(total_counts)
    by_scenario = [
        {
            "scenario": scenario,
            "imageCount": scenario_images[scenario],
            **metrics_from_counts(scenario_counts[scenario]),
        }
        for scenario in sorted(scenario_counts)
    ]
    failures = sorted(
        (
            row.as_json()
            for row in evaluations
            if row.counts.false_positive or row.counts.false_negative
        ),
        key=lambda row: (
            row["falsePositive"] + row["falseNegative"],
            row["falseNegative"],
            row["falsePositive"],
        ),
        reverse=True,
    )[:20]

    summary = {
        "schemaVersion": SCHEMA_VERSION,
        "runId": run_id,
        "createdAt": utc_now(),
        "component": "vision",
        "comparison": {
            "id": args.comparison_id,
            "trialIndex": args.trial_index,
            "trialCount": args.trial_count,
            "executionOrder": args.execution_order,
        },
        "model": {
            "name": model_name,
            "path": str(model_path),
            "runtime": runtime,
            "sizeBytes": model_path.stat().st_size,
            "sha256": sha256_file(model_path),
        },
        "dataset": {
            "name": dataset_name,
            "imageCount": len(pairs),
            "emptyImageCount": empty_count,
            "boxCount": box_count,
            "duplicateImageCount": duplicate_count,
            "sha256": fingerprint,
        },
        "configuration": {
            "device": args.device,
            "imgsz": args.imgsz,
            "batch": args.batch,
            "warmupFrames": args.warmup_frames,
            "mapConfidence": args.map_confidence,
            "operatingConfidence": args.operating_confidence,
            "nmsIou": args.nms_iou,
            "matchIou": args.match_iou,
            "classIds": [args.class_id],
        },
        "environment": {
            "python": platform.python_version(),
            "platform": platform.platform(),
            "ultralytics": ultralytics.__version__,
            "torch": torch.__version__,
            "cudaAvailable": torch.cuda.is_available(),
            "cudaVersion": torch.version.cuda,
            "cudnnVersion": torch.backends.cudnn.version(),
            "cudaDevice": (
                torch.cuda.get_device_name(0)
                if torch.cuda.is_available()
                else None
            ),
            "nvpmodel": command_output(["nvpmodel", "-q"]),
            "jetsonClocks": command_output(["jetson_clocks", "--show"]),
        },
        "metrics": {
            "measuredFrames": len(evaluations),
            "fps": rounded(1000.0 / mean_wall),
            "wallMeanMs": rounded(mean_wall),
            "wallP95Ms": rounded(percentile(wall_values, 0.95)),
            "inferenceMeanMs": rounded(
                statistics.fmean(inference_values)
                if inference_values
                else None
            ),
            "inferenceP95Ms": rounded(percentile(inference_values, 0.95)),
            "totalDetections": sum(
                row.prediction_count for row in evaluations
            ),
        },
        "accuracy": {
            "status": "computed",
            "standard": {
                "confidenceFloor": args.map_confidence,
                **map_metrics,
            },
            "operatingPoint": {
                "confidence": args.operating_confidence,
                "matchIou": args.match_iou,
                **operating,
            },
            "byScenario": by_scenario,
            "failureCases": failures,
        },
        "resources": summarize_resources(resources_path),
        "selectionPolicy": {
            "status": "provisional",
            "minimumFps": 20.0,
            "maximumWallP95Ms": 50.0,
            "minimumRecall": 0.9,
            "maximumMap50_95Gap": 0.02,
            "rule": (
                "Pass all service gates, remain within 0.02 mAP50-95 of "
                "the best model, then prefer higher FPS."
            ),
        },
    }
    write_json(output_dir / "summary.json", summary)
    temporary = output_dir / "frames.jsonl.tmp"
    with temporary.open("w", encoding="utf-8") as file:
        for row in evaluations:
            file.write(
                json.dumps(row.as_json(), ensure_ascii=False, separators=(",", ":"))
                + "\n"
            )
    temporary.replace(output_dir / "frames.jsonl")
    persist_progress("completed", "completed", total_progress)
    print(
        "PASS: "
        f"model={model_name} images={len(evaluations)} "
        f"mAP50-95={map_metrics['mAP50_95']} "
        f"operatingF1={operating['f1']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
