#!/usr/bin/env python3
"""Evaluate model-agnostic laughter or clap predictions on reviewed audio.

The model adapter and the metric calculation are intentionally separated.  Each
adapter writes one JSON Lines row per inference window, and this runner applies
the same aggregation, calibration, and test rules to every model.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import statistics
from typing import Any, Iterable, Sequence


SCHEMA_VERSION = "0.1"
PREDICTION_SCHEMA_VERSION = "0.1"
SCORE_AGGREGATIONS = ("max", "mean", "p90")
EVENT_TYPES = ("laughter", "clap")
COHORTS = ("localDirect", "continuousNegative", "externalGeneralization")
DEFAULT_POSITIVE_LABELS = {
    "laughter": {"laughter"},
    "clap": {"clap"},
}


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def percentile(values: Sequence[float], quantile: float) -> float:
    if not values:
        raise ValueError("values cannot be empty")
    if not 0.0 <= quantile <= 1.0:
        raise ValueError("quantile must be between zero and one")
    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def rounded(value: float | None, digits: int = 6) -> float | None:
    return None if value is None else round(float(value), digits)


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


@dataclass(frozen=True)
class DatasetSample:
    sample_id: str
    split: str
    positive: bool
    conditions: tuple[str, ...]
    duration_seconds: float | None


@dataclass(frozen=True)
class Prediction:
    sample_id: str
    score: float
    scores: dict[str, float]
    latency_ms: float
    duration_seconds: float | None
    top_class: str | None
    window_index: int | None
    offset_seconds: float | None


@dataclass(frozen=True)
class SampleResult:
    sample: DatasetSample
    score: float
    predicted_positive: bool
    top_class: str | None
    window_count: int


@dataclass(frozen=True)
class Counts:
    true_positive: int = 0
    false_positive: int = 0
    false_negative: int = 0
    true_negative: int = 0


def load_dataset(
    root: Path,
    *,
    positive_labels: set[str],
    allow_provisional: bool,
) -> tuple[dict[str, Any], dict[str, DatasetSample]]:
    manifest_path = root / "dataset.json"
    if not manifest_path.is_file():
        raise ValueError(f"dataset manifest does not exist: {manifest_path}")
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or not isinstance(payload.get("samples"), list):
        raise ValueError("dataset manifest must contain a samples array")

    samples: dict[str, DatasetSample] = {}
    for index, row in enumerate(payload["samples"]):
        if not isinstance(row, dict):
            raise ValueError(f"samples[{index}] must be an object")
        sample_id = row.get("sampleId")
        split = row.get("split")
        labels = row.get("labels")
        conditions = row.get("conditions")
        review = row.get("review")
        if not isinstance(sample_id, str) or not sample_id:
            raise ValueError(f"samples[{index}].sampleId is invalid")
        if sample_id in samples:
            raise ValueError(f"duplicate dataset sampleId: {sample_id}")
        if split not in {"train", "validation", "test"}:
            raise ValueError(f"sample {sample_id} has an invalid split")
        if not isinstance(labels, list) or not all(
            isinstance(label, str) for label in labels
        ):
            raise ValueError(f"sample {sample_id} labels must be strings")
        if not isinstance(conditions, list) or not all(
            isinstance(condition, str) for condition in conditions
        ):
            raise ValueError(f"sample {sample_id} conditions must be strings")
        review_status = review.get("status") if isinstance(review, dict) else None
        if review_status != "verified" and not allow_provisional:
            raise ValueError(
                f"sample {sample_id} is not verified; use --allow-provisional "
                "only for pipeline checks"
            )
        duration_value = row.get("durationSeconds")
        duration = float(duration_value) if duration_value is not None else None
        if duration is not None and duration <= 0:
            raise ValueError(f"sample {sample_id} durationSeconds must be positive")
        normalized_labels = {label.strip().lower() for label in labels}
        samples[sample_id] = DatasetSample(
            sample_id=sample_id,
            split=split,
            positive=bool(normalized_labels & positive_labels),
            conditions=tuple(sorted(set(conditions))),
            duration_seconds=duration,
        )
    return payload, samples


def load_predictions(path: Path) -> list[Prediction]:
    predictions: list[Prediction] = []
    with path.open("r", encoding="utf-8") as source:
        for line_number, line in enumerate(source, start=1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(
                    f"invalid prediction JSON at line {line_number}: {error}"
                ) from error
            if not isinstance(row, dict):
                raise ValueError(f"prediction line {line_number} must be an object")
            if row.get("schemaVersion") != PREDICTION_SCHEMA_VERSION:
                raise ValueError(
                    f"prediction line {line_number} has unsupported schemaVersion"
                )
            sample_id = row.get("sampleId")
            if not isinstance(sample_id, str) or not sample_id:
                raise ValueError(f"prediction line {line_number} has no sampleId")
            try:
                score = float(row["score"])
                latency = float(row["latencyMs"])
            except (KeyError, TypeError, ValueError) as error:
                raise ValueError(
                    f"prediction line {line_number} requires numeric score and latencyMs"
                ) from error
            if not 0.0 <= score <= 1.0:
                raise ValueError(f"prediction line {line_number} score is outside [0, 1]")
            if latency < 0:
                raise ValueError(f"prediction line {line_number} latencyMs is negative")
            scores_value = row.get("scores", {})
            if not isinstance(scores_value, dict):
                raise ValueError(f"prediction line {line_number} scores must be an object")
            scores: dict[str, float] = {}
            for event_type, value in scores_value.items():
                if event_type not in EVENT_TYPES:
                    continue
                try:
                    normalized = float(value)
                except (TypeError, ValueError) as error:
                    raise ValueError(
                        f"prediction line {line_number} has an invalid {event_type} score"
                    ) from error
                if not 0.0 <= normalized <= 1.0:
                    raise ValueError(
                        f"prediction line {line_number} {event_type} score is outside [0, 1]"
                    )
                scores[event_type] = normalized
            duration_value = row.get("durationSeconds")
            duration = float(duration_value) if duration_value is not None else None
            if duration is not None and duration <= 0:
                raise ValueError(
                    f"prediction line {line_number} durationSeconds must be positive"
                )
            window_value = row.get("windowIndex")
            window_index = int(window_value) if window_value is not None else None
            offset_value = row.get("offsetSeconds")
            offset_seconds = float(offset_value) if offset_value is not None else None
            if offset_seconds is not None and offset_seconds < 0:
                raise ValueError(
                    f"prediction line {line_number} offsetSeconds is negative"
                )
            top_class = row.get("topClass")
            if top_class is not None and not isinstance(top_class, str):
                raise ValueError(f"prediction line {line_number} topClass is invalid")
            predictions.append(
                Prediction(
                    sample_id=sample_id,
                    score=score,
                    scores=scores,
                    latency_ms=latency,
                    duration_seconds=duration,
                    top_class=top_class,
                    window_index=window_index,
                    offset_seconds=offset_seconds,
                )
            )
    if not predictions:
        raise ValueError(f"prediction file is empty: {path}")
    return predictions


def load_prediction_metadata(
    path: Path | None,
    *,
    dataset_root: Path,
    model_path: Path | None,
) -> dict[str, Any] | None:
    if path is None or not path.is_file():
        return None
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError("prediction metadata must be an object")
    dataset = payload.get("dataset")
    expected_manifest = sha256_file(dataset_root / "dataset.json")
    if (
        not isinstance(dataset, dict)
        or dataset.get("manifestSha256") != expected_manifest
    ):
        raise ValueError("prediction metadata dataset checksum mismatch")
    if model_path is not None:
        model = payload.get("model")
        if not isinstance(model, dict) or model.get("sha256") != sha256_file(model_path):
            raise ValueError("prediction metadata model checksum mismatch")
    return payload


def aggregate_scores(values: Sequence[float], aggregation: str) -> float:
    if not values:
        raise ValueError("score values cannot be empty")
    if aggregation == "max":
        return max(values)
    if aggregation == "mean":
        return statistics.fmean(values)
    if aggregation == "p90":
        return percentile(values, 0.90)
    raise ValueError(f"unsupported score aggregation: {aggregation}")


def group_predictions(
    samples: dict[str, DatasetSample],
    predictions: Iterable[Prediction],
    aggregation: str,
    event_type: str = "laughter",
    required_sample_ids: set[str] | None = None,
) -> dict[str, tuple[float, str | None, int, float | None]]:
    rows_by_sample: dict[str, list[Prediction]] = {}
    for prediction in predictions:
        if prediction.sample_id not in samples:
            raise ValueError(
                f"prediction references unknown sampleId: {prediction.sample_id}"
            )
        rows_by_sample.setdefault(prediction.sample_id, []).append(prediction)

    required = required_sample_ids if required_sample_ids is not None else set(samples)
    missing = sorted(required - set(rows_by_sample))
    if missing:
        raise ValueError(f"predictions are missing samples: {', '.join(missing[:8])}")

    grouped: dict[str, tuple[float, str | None, int, float | None]] = {}
    for sample_id, rows in rows_by_sample.items():
        event_scores = [prediction_score(row, event_type) for row in rows]
        score = aggregate_scores(event_scores, aggregation)
        best = max(rows, key=lambda row: prediction_score(row, event_type))
        durations = {row.duration_seconds for row in rows if row.duration_seconds is not None}
        if len(durations) > 1:
            raise ValueError(f"sample {sample_id} has conflicting durationSeconds")
        grouped[sample_id] = (
            score,
            best.top_class,
            len(rows),
            next(iter(durations)) if durations else None,
        )
    return grouped


def prediction_score(prediction: Prediction, event_type: str) -> float:
    if event_type in prediction.scores:
        return prediction.scores[event_type]
    if event_type == "laughter":
        return prediction.score
    raise ValueError(
        f"prediction for {prediction.sample_id} has no {event_type} score"
    )


def count_results(results: Iterable[SampleResult]) -> Counts:
    tp = fp = fn = tn = 0
    for result in results:
        if result.sample.positive and result.predicted_positive:
            tp += 1
        elif not result.sample.positive and result.predicted_positive:
            fp += 1
        elif result.sample.positive:
            fn += 1
        else:
            tn += 1
    return Counts(tp, fp, fn, tn)


def metrics_from_counts(counts: Counts) -> dict[str, float | int]:
    precision_denominator = counts.true_positive + counts.false_positive
    recall_denominator = counts.true_positive + counts.false_negative
    precision = (
        counts.true_positive / precision_denominator
        if precision_denominator
        else 0.0
    )
    recall = counts.true_positive / recall_denominator if recall_denominator else 0.0
    f1 = 2.0 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {
        "truePositive": counts.true_positive,
        "falsePositive": counts.false_positive,
        "falseNegative": counts.false_negative,
        "trueNegative": counts.true_negative,
        "precision": rounded(precision),
        "recall": rounded(recall),
        "f1": rounded(f1),
    }


def evaluate(
    samples: Iterable[DatasetSample],
    grouped: dict[str, tuple[float, str | None, int, float | None]],
    threshold: float,
) -> list[SampleResult]:
    return [
        SampleResult(
            sample=sample,
            score=grouped[sample.sample_id][0],
            predicted_positive=grouped[sample.sample_id][0] >= threshold,
            top_class=grouped[sample.sample_id][1],
            window_count=grouped[sample.sample_id][2],
        )
        for sample in samples
    ]


def select_threshold(
    samples: Sequence[DatasetSample],
    grouped: dict[str, tuple[float, str | None, int, float | None]],
    minimum_recall: float = 0.85,
) -> tuple[float, dict[str, float | int]]:
    if not samples:
        raise ValueError("threshold calibration split has no samples")
    if not any(sample.positive for sample in samples):
        raise ValueError("threshold calibration split has no positive samples")
    if not any(not sample.positive for sample in samples):
        raise ValueError("threshold calibration split has no negative samples")
    scores = sorted({grouped[sample.sample_id][0] for sample in samples})
    candidates = sorted({0.0, 1.0, *scores})
    if not 0.0 <= minimum_recall <= 1.0:
        raise ValueError("minimum recall must be between zero and one")
    evaluated: list[tuple[float, dict[str, Any]]] = []
    for threshold in candidates:
        metrics = metrics_from_counts(
            count_results(evaluate(samples, grouped, threshold))
        )
        evaluated.append((threshold, metrics))
    feasible = [
        row for row in evaluated if float(row[1]["recall"]) >= minimum_recall
    ]
    if feasible:
        threshold, metrics = max(
            feasible,
            key=lambda row: (
                -float(row[1]["falsePositive"]),
                float(row[1]["f1"]),
                float(row[1]["recall"]),
                float(row[1]["precision"]),
                row[0],
            ),
        )
    else:
        threshold, metrics = max(
            evaluated,
            key=lambda row: (
                float(row[1]["f1"]),
                float(row[1]["recall"]),
                float(row[1]["precision"]),
                row[0],
            ),
        )
    return threshold, metrics


def false_event_rate_per_hour(
    samples: Sequence[DatasetSample],
    predictions: Sequence[Prediction],
    *,
    event_type: str,
    threshold: float,
    required_consecutive_windows: int,
    cooldown_seconds: float,
    hop_seconds: float,
) -> tuple[float | None, int, float | None]:
    """Replay negative windows with the service-style consecutive/cooldown gate."""

    if required_consecutive_windows <= 0:
        raise ValueError("required consecutive windows must be positive")
    if cooldown_seconds < 0 or hop_seconds <= 0:
        raise ValueError("cooldown must be non-negative and hop must be positive")
    rows_by_sample: dict[str, list[Prediction]] = {}
    for prediction in predictions:
        rows_by_sample.setdefault(prediction.sample_id, []).append(prediction)
    false_events = 0
    durations: list[float] = []
    for sample in samples:
        if sample.positive:
            continue
        rows = sorted(
            rows_by_sample.get(sample.sample_id, []),
            key=lambda row: (
                row.offset_seconds
                if row.offset_seconds is not None
                else (row.window_index or 0) * hop_seconds
            ),
        )
        if not rows:
            continue
        duration = sample.duration_seconds or rows[0].duration_seconds
        if duration is None:
            return None, false_events, None
        durations.append(duration)
        consecutive = 0
        last_event_at: float | None = None
        for row in rows:
            offset = (
                row.offset_seconds
                if row.offset_seconds is not None
                else (row.window_index or 0) * hop_seconds
            )
            if prediction_score(row, event_type) < threshold:
                consecutive = 0
                continue
            consecutive += 1
            if consecutive < required_consecutive_windows:
                continue
            if last_event_at is None or offset - last_event_at >= cooldown_seconds:
                false_events += 1
                last_event_at = offset
            consecutive = 0
    total_seconds = sum(durations)
    if total_seconds <= 0:
        return None, false_events, None
    return false_events / (total_seconds / 3600.0), false_events, total_seconds


def false_positives_per_hour(
    results: Sequence[SampleResult],
    grouped: dict[str, tuple[float, str | None, int, float | None]],
) -> tuple[float | None, float | None]:
    negative_results = [result for result in results if not result.sample.positive]
    durations: list[float] = []
    for result in negative_results:
        prediction_duration = grouped[result.sample.sample_id][3]
        duration = result.sample.duration_seconds or prediction_duration
        if duration is None:
            return None, None
        durations.append(duration)
    total_seconds = sum(durations)
    if total_seconds <= 0:
        return None, None
    false_positives = sum(result.predicted_positive for result in negative_results)
    return false_positives / (total_seconds / 3600.0), total_seconds


def by_condition(
    results: Sequence[SampleResult],
) -> list[dict[str, float | int | str]]:
    conditions = sorted(
        {condition for result in results for condition in result.sample.conditions}
    )
    rows: list[dict[str, float | int | str]] = []
    for condition in conditions:
        selected = [
            result for result in results if condition in result.sample.conditions
        ]
        rows.append(
            {
                "condition": condition,
                "sampleCount": len(selected),
                **metrics_from_counts(count_results(selected)),
            }
        )
    return rows


def cohort_name(sample: DatasetSample) -> str:
    if "external-generalization" in sample.conditions:
        return "externalGeneralization"
    if sample.sample_id.startswith("test-continuous-negative-"):
        return "continuousNegative"
    return "localDirect"


def by_cohort(
    results: Sequence[SampleResult],
    grouped: dict[str, tuple[float, str | None, int, float | None]],
    predictions: Sequence[Prediction],
    *,
    event_type: str,
    threshold: float,
    required_consecutive_windows: int,
    cooldown_seconds: float,
    hop_seconds: float,
) -> dict[str, dict[str, float | int | None]]:
    """Measure each evidence cohort without diluting long-running false alarms."""

    rows: dict[str, dict[str, float | int | None]] = {}
    for name in COHORTS:
        selected_results = [
            result for result in results if cohort_name(result.sample) == name
        ]
        selected_samples = [result.sample for result in selected_results]
        if not selected_results:
            rows[name] = {
                "sampleCount": 0,
                "positiveSamples": 0,
                "negativeSamples": 0,
                **metrics_from_counts(Counts()),
                "falseEventsPerHour": None,
                "falseEventCount": 0,
                "negativeDurationSeconds": None,
                "falsePositiveClipsPerHour": None,
                "negativeClipDurationSeconds": None,
            }
            continue
        event_rate, false_event_count, negative_duration = (
            false_event_rate_per_hour(
                selected_samples,
                predictions,
                event_type=event_type,
                threshold=threshold,
                required_consecutive_windows=required_consecutive_windows,
                cooldown_seconds=cooldown_seconds,
                hop_seconds=hop_seconds,
            )
        )
        clip_rate, clip_duration = false_positives_per_hour(
            selected_results, grouped
        )
        rows[name] = {
            "sampleCount": len(selected_results),
            "positiveSamples": sum(
                result.sample.positive for result in selected_results
            ),
            "negativeSamples": sum(
                not result.sample.positive for result in selected_results
            ),
            **metrics_from_counts(count_results(selected_results)),
            "falseEventsPerHour": rounded(event_rate),
            "falseEventCount": false_event_count,
            "negativeDurationSeconds": rounded(negative_duration, 3),
            "falsePositiveClipsPerHour": rounded(clip_rate),
            "negativeClipDurationSeconds": rounded(clip_duration, 3),
        }
    return rows


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--prediction-metadata", type=Path)
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--evaluation-split", default="test", choices=("validation", "test"))
    parser.add_argument(
        "--calibration-split",
        default="validation",
        choices=("train", "validation"),
    )
    parser.add_argument("--threshold", type=float)
    parser.add_argument("--event-type", choices=EVENT_TYPES, default="laughter")
    parser.add_argument("--positive-label", action="append", default=[])
    parser.add_argument("--minimum-recall", type=float, default=0.85)
    parser.add_argument("--required-consecutive-windows", type=int, default=2)
    parser.add_argument("--cooldown-seconds", type=float, default=12.0)
    parser.add_argument("--hop-seconds", type=float, default=0.4875)
    parser.add_argument("--score-aggregation", choices=SCORE_AGGREGATIONS, default="max")
    parser.add_argument("--allow-provisional", action="store_true")
    parser.add_argument("--comparison-id")
    parser.add_argument("--trial-index", type=int)
    parser.add_argument("--trial-count", type=int)
    parser.add_argument("--execution-order", type=int)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    dataset_root = args.dataset_root.expanduser().resolve()
    prediction_path = args.predictions.expanduser().resolve()
    metadata_path = (
        args.prediction_metadata.expanduser().resolve()
        if args.prediction_metadata
        else prediction_path.parent / "prediction-metadata.json"
    )
    output_dir = args.output_dir.expanduser().resolve()
    model_path = args.model.expanduser().resolve() if args.model else None
    if not prediction_path.is_file():
        raise SystemExit(f"ERROR: prediction file does not exist: {prediction_path}")
    if args.prediction_metadata and not metadata_path.is_file():
        raise SystemExit(
            f"ERROR: prediction metadata does not exist: {metadata_path}"
        )
    if model_path is not None and not model_path.is_file():
        raise SystemExit(f"ERROR: model file does not exist: {model_path}")
    if args.threshold is not None and not 0.0 <= args.threshold <= 1.0:
        raise SystemExit("ERROR: threshold must be between zero and one")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise SystemExit(f"ERROR: output directory is not empty: {output_dir}")

    positive_labels = {
        label.strip().lower()
        for label in (
            args.positive_label or sorted(DEFAULT_POSITIVE_LABELS[args.event_type])
        )
    }
    try:
        dataset, samples = load_dataset(
            dataset_root,
            positive_labels=positive_labels,
            allow_provisional=args.allow_provisional,
        )
        predictions = load_predictions(prediction_path)
        prediction_metadata = load_prediction_metadata(
            metadata_path if metadata_path.is_file() else None,
            dataset_root=dataset_root,
            model_path=model_path,
        )
        prediction_configuration = (
            prediction_metadata.get("configuration")
            if isinstance(prediction_metadata, dict)
            and isinstance(prediction_metadata.get("configuration"), dict)
            else {}
        )
        window_value = prediction_configuration.get("windowSeconds")
        window_seconds = (
            float(window_value)
            if isinstance(window_value, (int, float))
            and not isinstance(window_value, bool)
            else None
        )
        metadata_hop_value = prediction_configuration.get("hopSeconds")
        metadata_hop_seconds = (
            float(metadata_hop_value)
            if isinstance(metadata_hop_value, (int, float))
            and not isinstance(metadata_hop_value, bool)
            else None
        )
        prediction_precision_value = prediction_configuration.get("precision")
        prediction_precision = (
            str(prediction_precision_value)
            if isinstance(prediction_precision_value, str)
            else None
        )
        if window_seconds is not None and window_seconds <= 0:
            raise ValueError("prediction metadata windowSeconds must be positive")
        if metadata_hop_seconds is not None and not math.isclose(
            metadata_hop_seconds,
            args.hop_seconds,
            rel_tol=0.0,
            abs_tol=1e-9,
        ):
            raise ValueError(
                "prediction metadata hopSeconds does not match evaluation hop"
            )
        evaluation_samples = [
            sample for sample in samples.values() if sample.split == args.evaluation_split
        ]
        if not evaluation_samples:
            raise ValueError("evaluation split has no samples")
        required_sample_ids = {sample.sample_id for sample in evaluation_samples}
        if args.threshold is None:
            calibration_samples = [
                sample
                for sample in samples.values()
                if sample.split == args.calibration_split
            ]
            required_sample_ids.update(
                sample.sample_id for sample in calibration_samples
            )
        grouped = group_predictions(
            samples,
            predictions,
            args.score_aggregation,
            args.event_type,
            required_sample_ids,
        )
        if args.threshold is None:
            threshold, calibration_metrics = select_threshold(
                calibration_samples,
                grouped,
                args.minimum_recall,
            )
            threshold_source = args.calibration_split
        else:
            threshold = args.threshold
            calibration_metrics = None
            threshold_source = "fixed"
    except (json.JSONDecodeError, OSError, ValueError) as error:
        raise SystemExit(f"ERROR: {error}") from error

    results = evaluate(evaluation_samples, grouped, threshold)
    counts = count_results(results)
    operating = metrics_from_counts(counts)
    clip_fp_per_hour, clip_negative_duration = false_positives_per_hour(
        results, grouped
    )
    event_fp_per_hour, false_event_count, negative_duration = (
        false_event_rate_per_hour(
            evaluation_samples,
            predictions,
            event_type=args.event_type,
            threshold=threshold,
            required_consecutive_windows=args.required_consecutive_windows,
            cooldown_seconds=args.cooldown_seconds,
            hop_seconds=args.hop_seconds,
        )
    )
    operating["falsePositivesPerHour"] = rounded(event_fp_per_hour)
    operating["falseEventCount"] = false_event_count
    operating["negativeDurationSeconds"] = rounded(negative_duration, 3)
    operating["falsePositiveClipsPerHour"] = rounded(clip_fp_per_hour)
    operating["negativeClipDurationSeconds"] = rounded(
        clip_negative_duration, 3
    )

    used_sample_ids = {sample.sample_id for sample in evaluation_samples}
    latency_values = [
        prediction.latency_ms
        for prediction in predictions
        if prediction.sample_id in used_sample_ids
    ]
    score_values = [result.score for result in results]
    minimum_positive_span_seconds = (
        window_seconds
        + (args.required_consecutive_windows - 1) * args.hop_seconds
        if window_seconds is not None
        else None
    )
    output_dir.mkdir(parents=True, exist_ok=True)

    evaluated_rows = []
    for result in sorted(results, key=lambda row: row.sample.sample_id):
        outcome = (
            "true_positive"
            if result.sample.positive and result.predicted_positive
            else "false_positive"
            if not result.sample.positive and result.predicted_positive
            else "false_negative"
            if result.sample.positive
            else "true_negative"
        )
        evaluated_rows.append(
            {
                "sampleId": result.sample.sample_id,
                "split": result.sample.split,
                "conditions": list(result.sample.conditions),
                "groundTruthPositive": result.sample.positive,
                "score": rounded(result.score),
                "threshold": rounded(threshold),
                "predictedPositive": result.predicted_positive,
                "outcome": outcome,
                "topClass": result.top_class,
                "windowCount": result.window_count,
            }
        )
    (output_dir / "predictions-evaluated.jsonl").write_text(
        "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in evaluated_rows),
        encoding="utf-8",
    )

    model_payload: dict[str, Any] = {
        "name": args.model_name,
        "runtime": args.runtime,
    }
    if model_path is not None:
        model_payload.update(
            {
                "path": str(model_path),
                "sizeBytes": model_path.stat().st_size,
                "sha256": sha256_file(model_path),
            }
        )
    comparison = None
    if args.comparison_id:
        comparison = {
            "id": args.comparison_id,
            "trialIndex": args.trial_index,
            "trialCount": args.trial_count,
            "executionOrder": args.execution_order,
        }
    failures = [
        {
            "sampleId": row["sampleId"],
            "conditions": row["conditions"],
            "outcome": row["outcome"],
            "score": row["score"],
        }
        for row in evaluated_rows
        if row["outcome"] in {"false_positive", "false_negative"}
    ]
    run_id = output_dir.name
    summary = {
        "schemaVersion": SCHEMA_VERSION,
        "runId": run_id,
        "createdAt": utc_now(),
        "component": "audio",
        "comparison": comparison,
        "model": model_payload,
        "dataset": {
            "name": dataset.get("name", dataset_root.name),
            "path": str(dataset_root),
            "manifestSha256": sha256_file(dataset_root / "dataset.json"),
            "evaluationSplit": args.evaluation_split,
            "sampleCount": len(evaluation_samples),
            "positiveSamples": sum(sample.positive for sample in evaluation_samples),
            "negativeSamples": sum(not sample.positive for sample in evaluation_samples),
        },
        "configuration": {
            "positiveLabels": sorted(positive_labels),
            "eventType": args.event_type,
            "scoreAggregation": args.score_aggregation,
            "threshold": rounded(threshold),
            "thresholdSource": threshold_source,
            "calibrationSplit": (
                args.calibration_split if args.threshold is None else None
            ),
            "allowProvisional": args.allow_provisional,
            "minimumRecall": args.minimum_recall,
            "requiredConsecutiveWindows": args.required_consecutive_windows,
            "cooldownSeconds": args.cooldown_seconds,
            "hopSeconds": args.hop_seconds,
            "windowSeconds": rounded(window_seconds, 6),
            "minimumPositiveSpanSeconds": rounded(
                minimum_positive_span_seconds,
                6,
            ),
            "precision": prediction_precision,
        },
        "metrics": {
            "measuredSamples": len(evaluation_samples),
            "measuredWindows": len(latency_values),
            "inferenceMeanMs": rounded(statistics.fmean(latency_values), 3),
            "inferenceP95Ms": rounded(percentile(latency_values, 0.95), 3),
            "scoreMean": rounded(statistics.fmean(score_values)),
            "scoreP95": rounded(percentile(score_values, 0.95)),
        },
        "resources": (
            prediction_metadata.get("resources")
            if isinstance(prediction_metadata, dict)
            and isinstance(prediction_metadata.get("resources"), dict)
            else {"status": "not-collected", "sampleCount": 0}
        ),
        "selectionPolicy": {
            "status": "service-gates-defined",
            "minimumRecall": args.minimum_recall,
            "maximumFalsePositivesPerHour": 1.0,
            "priority": "false-positive-rate-then-recall-f1-and-latency",
        },
        "predictionMetadata": (
            {
                "source": prediction_metadata.get("source"),
                "classMap": prediction_metadata.get("classMap"),
                "configuration": prediction_metadata.get("configuration"),
                "predictionCount": prediction_metadata.get("predictionCount"),
            }
            if isinstance(prediction_metadata, dict)
            else None
        ),
        "accuracy": {
            "status": "computed",
            "task": f"binary-{args.event_type}-detection",
            "eventType": args.event_type,
            "selectionPolicy": {
                "priority": "minimize-false-positives-then-recall-and-f1",
                "minimumRecall": args.minimum_recall,
                "maximumFalsePositivesPerHour": 1.0,
            },
            "calibration": (
                {
                    "split": args.calibration_split,
                    "threshold": rounded(threshold),
                    **calibration_metrics,
                }
                if calibration_metrics is not None
                else None
            ),
            "operatingPoint": {
                "threshold": rounded(threshold),
                **operating,
            },
            "byCohort": by_cohort(
                results,
                grouped,
                predictions,
                event_type=args.event_type,
                threshold=threshold,
                required_consecutive_windows=args.required_consecutive_windows,
                cooldown_seconds=args.cooldown_seconds,
                hop_seconds=args.hop_seconds,
            ),
            "byCondition": by_condition(results),
            "failureCases": failures,
        },
    }
    atomic_write_json(output_dir / "summary.json", summary)
    atomic_write_json(
        output_dir / "progress.json",
        {
            "schemaVersion": SCHEMA_VERSION,
            "runId": run_id,
            "updatedAt": utc_now(),
            "status": "completed",
            "component": "audio",
            "model": args.model_name,
            "runtime": args.runtime,
            "dataset": summary["dataset"]["name"],
            "progress": {
                "completedSamples": len(evaluation_samples),
                "totalSamples": len(evaluation_samples),
                "percent": 100.0,
                "stage": "completed",
            },
        },
    )
    print(
        "PASS: audio accuracy evaluated "
        f"model={args.model_name} samples={len(evaluation_samples)} "
        f"precision={operating['precision']} recall={operating['recall']} "
        f"f1={operating['f1']} threshold={rounded(threshold)}"
    )
    print(f"RESULTS_DIR={output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
