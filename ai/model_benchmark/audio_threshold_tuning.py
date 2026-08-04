#!/usr/bin/env python3
"""Re-evaluate stored audio predictions for recall-focused service tuning.

The original benchmark remains immutable.  This tool replays its raw window
scores with a service-style consecutive-window gate, builds validation Pareto
frontiers, and applies the selected candidates to the already-observed test
split as post-hoc diagnostics.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import math
from pathlib import Path
import statistics
from typing import Any, Iterable, Sequence

from audio_accuracy_runner import (
    COHORTS,
    DEFAULT_POSITIVE_LABELS,
    EVENT_TYPES,
    Counts,
    DatasetSample,
    Prediction,
    SampleResult,
    atomic_write_json,
    cohort_name,
    count_results,
    false_event_rate_per_hour,
    load_dataset,
    load_prediction_metadata,
    load_predictions,
    metrics_from_counts,
    prediction_score,
    rounded,
    sha256_file,
    utc_now,
)


SCHEMA_VERSION = "0.1"
DEFAULT_CONSECUTIVE_WINDOWS = (1, 2, 3)


@dataclass(frozen=True)
class RunSource:
    model_name: str
    runtime: str
    trial_index: int
    run_dir: Path
    predictions: tuple[Prediction, ...]
    rows_by_sample: dict[str, tuple[Prediction, ...]]
    window_seconds: float
    hop_seconds: float
    precision: str | None
    current_thresholds: dict[str, float]
    current_consecutive_windows: int


def mean(values: Iterable[float | int | None]) -> float | None:
    selected = [float(value) for value in values if value is not None]
    return rounded(statistics.fmean(selected)) if selected else None


def minimum(values: Iterable[float | int | None]) -> float | None:
    selected = [float(value) for value in values if value is not None]
    return rounded(min(selected)) if selected else None


def maximum(values: Iterable[float | int | None]) -> float | None:
    selected = [float(value) for value in values if value is not None]
    return rounded(max(selected)) if selected else None


def f_beta(precision: float, recall: float, beta: float = 2.0) -> float:
    if beta <= 0:
        raise ValueError("beta must be positive")
    denominator = beta * beta * precision + recall
    if denominator == 0:
        return 0.0
    return (1 + beta * beta) * precision * recall / denominator


def group_rows(predictions: Iterable[Prediction]) -> dict[str, tuple[Prediction, ...]]:
    grouped: dict[str, list[Prediction]] = {}
    for prediction in predictions:
        grouped.setdefault(prediction.sample_id, []).append(prediction)
    return {
        sample_id: tuple(
            sorted(
                rows,
                key=lambda row: (
                    row.offset_seconds
                    if row.offset_seconds is not None
                    else row.window_index or 0
                ),
            )
        )
        for sample_id, rows in grouped.items()
    }


def detects_event(
    rows: Sequence[Prediction],
    *,
    event_type: str,
    threshold: float,
    required_consecutive_windows: int,
) -> bool:
    if required_consecutive_windows <= 0:
        raise ValueError("required consecutive windows must be positive")
    consecutive = 0
    for row in rows:
        if prediction_score(row, event_type) >= threshold:
            consecutive += 1
            if consecutive >= required_consecutive_windows:
                return True
        else:
            consecutive = 0
    return False


def evaluate_window_gate(
    samples: Sequence[DatasetSample],
    rows_by_sample: dict[str, tuple[Prediction, ...]],
    *,
    event_type: str,
    threshold: float,
    required_consecutive_windows: int,
) -> list[SampleResult]:
    results: list[SampleResult] = []
    for sample in samples:
        rows = rows_by_sample.get(sample.sample_id)
        if not rows:
            raise ValueError(f"predictions are missing sample: {sample.sample_id}")
        scores = [prediction_score(row, event_type) for row in rows]
        best = max(rows, key=lambda row: prediction_score(row, event_type))
        results.append(
            SampleResult(
                sample=sample,
                score=max(scores),
                predicted_positive=detects_event(
                    rows,
                    event_type=event_type,
                    threshold=threshold,
                    required_consecutive_windows=required_consecutive_windows,
                ),
                top_class=best.top_class,
                window_count=len(rows),
            )
        )
    return results


def negative_clip_rate(results: Sequence[SampleResult]) -> tuple[float | None, float]:
    negatives = [result for result in results if not result.sample.positive]
    durations = [result.sample.duration_seconds for result in negatives]
    if any(duration is None for duration in durations):
        return None, 0.0
    total_seconds = sum(float(duration) for duration in durations if duration is not None)
    if total_seconds <= 0:
        return None, total_seconds
    false_positives = sum(result.predicted_positive for result in negatives)
    return false_positives / (total_seconds / 3600.0), total_seconds


def run_metrics(results: Sequence[SampleResult]) -> dict[str, float | int | None]:
    metrics = metrics_from_counts(count_results(results))
    precision = float(metrics["precision"])
    recall = float(metrics["recall"])
    clip_rate, negative_duration = negative_clip_rate(results)
    return {
        **metrics,
        "f2": rounded(f_beta(precision, recall)),
        "falsePositiveClipsPerHour": rounded(clip_rate),
        "negativeClipDurationSeconds": rounded(negative_duration, 3),
    }


def aggregate_metrics(rows: Sequence[dict[str, float | int | None]]) -> dict[str, Any]:
    return {
        "trialCount": len(rows),
        "precisionMean": mean(row["precision"] for row in rows),
        "precisionMin": minimum(row["precision"] for row in rows),
        "recallMean": mean(row["recall"] for row in rows),
        "recallMin": minimum(row["recall"] for row in rows),
        "f1Mean": mean(row["f1"] for row in rows),
        "f2Mean": mean(row["f2"] for row in rows),
        "falsePositiveMean": mean(row["falsePositive"] for row in rows),
        "falsePositiveMax": maximum(row["falsePositive"] for row in rows),
        "falseNegativeMean": mean(row["falseNegative"] for row in rows),
        "falseNegativeMax": maximum(row["falseNegative"] for row in rows),
        "falsePositiveClipsPerHourMean": mean(
            row["falsePositiveClipsPerHour"] for row in rows
        ),
        "falsePositiveClipsPerHourMax": maximum(
            row["falsePositiveClipsPerHour"] for row in rows
        ),
    }


def evaluate_candidate(
    runs: Sequence[RunSource],
    samples: Sequence[DatasetSample],
    *,
    event_type: str,
    threshold: float,
    required_consecutive_windows: int,
) -> tuple[dict[str, Any], list[list[SampleResult]]]:
    trial_results = [
        evaluate_window_gate(
            samples,
            run.rows_by_sample,
            event_type=event_type,
            threshold=threshold,
            required_consecutive_windows=required_consecutive_windows,
        )
        for run in runs
    ]
    metrics = aggregate_metrics([run_metrics(results) for results in trial_results])
    first = runs[0]
    return (
        {
            "threshold": float(threshold),
            "requiredConsecutiveWindows": required_consecutive_windows,
            "minimumPositiveSpanSeconds": rounded(
                first.window_seconds
                + (required_consecutive_windows - 1) * first.hop_seconds,
                6,
            ),
            **metrics,
        },
        trial_results,
    )


def dominates(left: dict[str, Any], right: dict[str, Any]) -> bool:
    left_recall = float(left["recallMin"])
    right_recall = float(right["recallMin"])
    left_fp = float(left["falsePositiveClipsPerHourMax"])
    right_fp = float(right["falsePositiveClipsPerHourMax"])
    return (
        left_recall >= right_recall
        and left_fp <= right_fp
        and (left_recall > right_recall or left_fp < right_fp)
    )


def pareto_frontier(candidates: Sequence[dict[str, Any]]) -> list[dict[str, Any]]:
    frontier = [
        candidate
        for candidate in candidates
        if not any(
            other is not candidate and dominates(other, candidate)
            for other in candidates
        )
    ]
    deduplicated: dict[tuple[float, float], dict[str, Any]] = {}
    for candidate in frontier:
        key = (
            float(candidate["recallMin"]),
            float(candidate["falsePositiveClipsPerHourMax"]),
        )
        current = deduplicated.get(key)
        candidate_key = (
            float(candidate["f2Mean"]),
            float(candidate["precisionMean"]),
            -float(candidate["minimumPositiveSpanSeconds"]),
            float(candidate["threshold"]),
        )
        if current is None:
            deduplicated[key] = candidate
        else:
            current_key = (
                float(current["f2Mean"]),
                float(current["precisionMean"]),
                -float(current["minimumPositiveSpanSeconds"]),
                float(current["threshold"]),
            )
            if candidate_key > current_key:
                deduplicated[key] = candidate
    return sorted(
        deduplicated.values(),
        key=lambda row: (
            -float(row["recallMin"]),
            float(row["falsePositiveClipsPerHourMax"]),
            -float(row["f2Mean"]),
        ),
    )


def candidate_key(row: dict[str, Any]) -> tuple[float, float, float, float, float]:
    return (
        float(row["f2Mean"]),
        float(row["recallMin"]),
        -float(row["falsePositiveClipsPerHourMax"]),
        float(row["precisionMean"]),
        -float(row["minimumPositiveSpanSeconds"]),
    )


def representative_candidates(
    candidates: Sequence[dict[str, Any]],
    frontier: Sequence[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    maximum_recall = max(
        candidates,
        key=lambda row: (
            float(row["recallMin"]),
            -float(row["falsePositiveClipsPerHourMax"]),
            float(row["f2Mean"]),
            -float(row["minimumPositiveSpanSeconds"]),
        ),
    )
    maximum_f2 = max(candidates, key=candidate_key)
    shadow_candidate = max(frontier, key=candidate_key)
    return {
        "maximumRecall": maximum_recall,
        "maximumF2": maximum_f2,
        "shadowCandidate": shadow_candidate,
    }


def threshold_candidates(
    runs: Sequence[RunSource],
    validation_ids: set[str],
    event_type: str,
) -> list[float]:
    values = {0.0, 1.0}
    for run in runs:
        values.add(run.current_thresholds[event_type])
        values.update(
            prediction_score(prediction, event_type)
            for prediction in run.predictions
            if prediction.sample_id in validation_ids
        )
    return sorted(values)


def load_summary(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"summary must be an object: {path}")
    return payload


def discover_runs(results_dir: Path, dataset_root: Path) -> dict[str, list[RunSource]]:
    discovered: dict[str, list[RunSource]] = {}
    for prediction_path in sorted(results_dir.glob("round-*/*/predictions.jsonl")):
        run_dir = prediction_path.parent
        laughter_summary_path = run_dir / "evaluation-laughter" / "summary.json"
        clap_summary_path = run_dir / "evaluation-clap" / "summary.json"
        metadata_path = run_dir / "prediction-metadata.json"
        required = (laughter_summary_path, clap_summary_path, metadata_path)
        if not all(path.is_file() for path in required):
            raise ValueError(f"incomplete benchmark run: {run_dir}")
        laughter_summary = load_summary(laughter_summary_path)
        clap_summary = load_summary(clap_summary_path)
        model = laughter_summary.get("model")
        if not isinstance(model, dict) or not isinstance(model.get("name"), str):
            raise ValueError(f"summary has no model name: {laughter_summary_path}")
        model_name = model["name"]
        if clap_summary.get("model", {}).get("name") != model_name:
            raise ValueError(f"event summaries disagree on model: {run_dir}")
        comparison = laughter_summary.get("comparison")
        trial_index = (
            int(comparison.get("trialIndex"))
            if isinstance(comparison, dict) and comparison.get("trialIndex") is not None
            else len(discovered.get(model_name, [])) + 1
        )
        metadata = load_prediction_metadata(
            metadata_path,
            dataset_root=dataset_root,
            model_path=None,
        )
        configuration = metadata.get("configuration") if isinstance(metadata, dict) else None
        if not isinstance(configuration, dict):
            raise ValueError(f"prediction metadata has no configuration: {metadata_path}")
        window_seconds = float(configuration["windowSeconds"])
        hop_seconds = float(configuration["hopSeconds"])
        if window_seconds <= 0 or hop_seconds <= 0:
            raise ValueError(f"invalid window configuration: {metadata_path}")
        event_summaries = {
            "laughter": laughter_summary,
            "clap": clap_summary,
        }
        thresholds: dict[str, float] = {}
        current_consecutive: int | None = None
        for event_type, summary in event_summaries.items():
            summary_configuration = summary.get("configuration")
            if not isinstance(summary_configuration, dict):
                raise ValueError(f"summary has no configuration: {run_dir}")
            thresholds[event_type] = float(summary_configuration["threshold"])
            consecutive = int(summary_configuration["requiredConsecutiveWindows"])
            if current_consecutive is None:
                current_consecutive = consecutive
            elif current_consecutive != consecutive:
                raise ValueError(f"event summaries disagree on window gate: {run_dir}")
        predictions = tuple(load_predictions(prediction_path))
        discovered.setdefault(model_name, []).append(
            RunSource(
                model_name=model_name,
                runtime=str(model.get("runtime") or "unknown"),
                trial_index=trial_index,
                run_dir=run_dir,
                predictions=predictions,
                rows_by_sample=group_rows(predictions),
                window_seconds=window_seconds,
                hop_seconds=hop_seconds,
                precision=(
                    str(configuration.get("precision"))
                    if configuration.get("precision") is not None
                    else None
                ),
                current_thresholds=thresholds,
                current_consecutive_windows=current_consecutive or 1,
            )
        )
    if not discovered:
        raise ValueError("no completed raw prediction runs were found")
    for runs in discovered.values():
        runs.sort(key=lambda run: run.trial_index)
        reference = runs[0]
        for run in runs[1:]:
            if not math.isclose(run.window_seconds, reference.window_seconds) or not math.isclose(
                run.hop_seconds, reference.hop_seconds
            ):
                raise ValueError(f"model runs disagree on streaming configuration: {run.model_name}")
    return discovered


def aggregate_test_candidate(
    runs: Sequence[RunSource],
    samples: Sequence[DatasetSample],
    *,
    event_type: str,
    threshold: float,
    required_consecutive_windows: int,
    cooldown_seconds: float,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    candidate, trial_results = evaluate_candidate(
        runs,
        samples,
        event_type=event_type,
        threshold=threshold,
        required_consecutive_windows=required_consecutive_windows,
    )
    candidate.pop("threshold")
    candidate.pop("requiredConsecutiveWindows")
    candidate.pop("minimumPositiveSpanSeconds")
    by_cohort: dict[str, dict[str, Any]] = {}
    for cohort in COHORTS:
        trial_rows: list[dict[str, Any]] = []
        for run, results in zip(runs, trial_results):
            selected_results = [
                result for result in results if cohort_name(result.sample) == cohort
            ]
            selected_samples = [result.sample for result in selected_results]
            metrics = run_metrics(selected_results) if selected_results else run_metrics([])
            event_rate, event_count, negative_seconds = false_event_rate_per_hour(
                selected_samples,
                run.predictions,
                event_type=event_type,
                threshold=threshold,
                required_consecutive_windows=required_consecutive_windows,
                cooldown_seconds=cooldown_seconds,
                hop_seconds=run.hop_seconds,
            )
            trial_rows.append(
                {
                    **metrics,
                    "falseEventsPerHour": rounded(event_rate),
                    "falseEventCount": event_count,
                    "negativeDurationSeconds": rounded(negative_seconds, 3),
                }
            )
        by_cohort[cohort] = {
            **aggregate_metrics(trial_rows),
            "sampleCount": sum(
                1 for sample in samples if cohort_name(sample) == cohort
            ),
            "falseEventsPerHourMean": mean(
                row["falseEventsPerHour"] for row in trial_rows
            ),
            "falseEventsPerHourMax": maximum(
                row["falseEventsPerHour"] for row in trial_rows
            ),
            "falseEventCountMax": maximum(
                row["falseEventCount"] for row in trial_rows
            ),
            "negativeDurationSeconds": maximum(
                row["negativeDurationSeconds"] for row in trial_rows
            ),
        }
    failures: list[dict[str, Any]] = []
    for run, results in zip(runs, trial_results):
        for result in results:
            outcome = (
                "false_negative"
                if result.sample.positive and not result.predicted_positive
                else "false_positive"
                if not result.sample.positive and result.predicted_positive
                else None
            )
            if outcome is not None:
                failures.append(
                    {
                        "model": run.model_name,
                        "eventType": event_type,
                        "trialIndex": run.trial_index,
                        "sampleId": result.sample.sample_id,
                        "conditions": list(result.sample.conditions),
                        "outcome": outcome,
                        "score": rounded(result.score),
                        "threshold": rounded(threshold, 9),
                        "requiredConsecutiveWindows": required_consecutive_windows,
                    }
                )
    return {"overall": candidate, "byCohort": by_cohort}, failures


def enrich_candidate(
    candidate: dict[str, Any],
    runs: Sequence[RunSource],
    test_samples: Sequence[DatasetSample],
    *,
    event_type: str,
    cooldown_seconds: float,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    test, failures = aggregate_test_candidate(
        runs,
        test_samples,
        event_type=event_type,
        threshold=float(candidate["threshold"]),
        required_consecutive_windows=int(candidate["requiredConsecutiveWindows"]),
        cooldown_seconds=cooldown_seconds,
    )
    return {"validation": candidate, "testDiagnostic": test}, failures


def mixed_event_diagnostic(
    runs: Sequence[RunSource],
    laughter_samples: dict[str, DatasetSample],
    laughter_candidate: dict[str, Any],
    clap_candidate: dict[str, Any],
) -> dict[str, Any]:
    mixed_ids = sorted(
        sample.sample_id
        for sample in laughter_samples.values()
        if sample.split == "test" and "laughter-with-clap" in sample.conditions
    )
    trial_rows: list[dict[str, Any]] = []
    missed: set[str] = set()
    for run in runs:
        laughter_detected = clap_detected = both_detected = 0
        for sample_id in mixed_ids:
            rows = run.rows_by_sample[sample_id]
            laughter = detects_event(
                rows,
                event_type="laughter",
                threshold=float(laughter_candidate["threshold"]),
                required_consecutive_windows=int(
                    laughter_candidate["requiredConsecutiveWindows"]
                ),
            )
            clap = detects_event(
                rows,
                event_type="clap",
                threshold=float(clap_candidate["threshold"]),
                required_consecutive_windows=int(
                    clap_candidate["requiredConsecutiveWindows"]
                ),
            )
            laughter_detected += laughter
            clap_detected += clap
            both_detected += laughter and clap
            if not (laughter and clap):
                missed.add(sample_id)
        denominator = len(mixed_ids)
        trial_rows.append(
            {
                "laughterRecall": laughter_detected / denominator if denominator else 0.0,
                "clapRecall": clap_detected / denominator if denominator else 0.0,
                "bothDetectedRate": both_detected / denominator if denominator else 0.0,
            }
        )
    return {
        "status": "post-hoc-diagnostic",
        "sampleCount": len(mixed_ids),
        "laughterRecallMean": mean(row["laughterRecall"] for row in trial_rows),
        "laughterRecallMin": minimum(row["laughterRecall"] for row in trial_rows),
        "clapRecallMean": mean(row["clapRecall"] for row in trial_rows),
        "clapRecallMin": minimum(row["clapRecall"] for row in trial_rows),
        "bothDetectedRateMean": mean(row["bothDetectedRate"] for row in trial_rows),
        "bothDetectedRateMin": minimum(row["bothDetectedRate"] for row in trial_rows),
        "missedSampleIds": sorted(missed),
    }


def format_number(value: Any, digits: int = 3) -> str:
    return "N/A" if value is None else f"{float(value):.{digits}f}"


def markdown_report(payload: dict[str, Any], max_pareto_rows: int) -> str:
    lines = [
        "# 오디오 이벤트 Recall–오탐 임계값 재튜닝",
        "",
        f"- 비교 ID: `{payload['comparisonId']}`",
        f"- 데이터셋: `{payload['dataset']['name']}`",
        "- 후보는 validation에서 만들고 test는 이미 관찰된 사후 진단으로만 사용했다.",
        "- 섀도 후보는 validation Pareto 전선에서 F2가 가장 높은 운영점이다.",
        "- 한 번의 실제 사람 이벤트를 놓치는 비용을 줄이되 오탐도 함께 공개한다.",
        "",
        "## 추천 섀도 후보",
        "",
        "| 모델 | 이벤트 | 임계값 | 연속 창 | 최소 구간 초 | Validation Recall 최저 | Validation F2 평균 | Validation FP clip/h 최대 | Test Recall 최저 | 연속 음성 FP event/h 최대 |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for model in payload["models"]:
        for event_type in EVENT_TYPES:
            candidate = model["events"][event_type]["shadowCandidate"]
            validation = candidate["validation"]
            test = candidate["testDiagnostic"]
            continuous = test["byCohort"]["continuousNegative"]
            lines.append(
                f"| {model['model']} | {event_type} | "
                f"{format_number(validation['threshold'], 6)} | "
                f"{validation['requiredConsecutiveWindows']} | "
                f"{format_number(validation['minimumPositiveSpanSeconds'])} | "
                f"{format_number(validation['recallMin'])} | "
                f"{format_number(validation['f2Mean'])} | "
                f"{format_number(validation['falsePositiveClipsPerHourMax'], 2)} | "
                f"{format_number(test['overall']['recallMin'])} | "
                f"{format_number(continuous['falseEventsPerHourMax'], 2)} |"
            )
    lines.extend(["", "## Validation Pareto 후보", ""])
    for model in payload["models"]:
        for event_type in EVENT_TYPES:
            lines.extend(
                [
                    f"### {model['model']} · {event_type}",
                    "",
                    "| 임계값 | 연속 창 | Recall 최저 | Precision 평균 | F2 평균 | FP clip/h 최대 |",
                    "| ---: | ---: | ---: | ---: | ---: | ---: |",
                ]
            )
            rows = model["events"][event_type]["paretoFrontier"]
            for candidate in rows[:max_pareto_rows]:
                validation = candidate["validation"]
                lines.append(
                    f"| {format_number(validation['threshold'], 6)} | "
                    f"{validation['requiredConsecutiveWindows']} | "
                    f"{format_number(validation['recallMin'])} | "
                    f"{format_number(validation['precisionMean'])} | "
                    f"{format_number(validation['f2Mean'])} | "
                    f"{format_number(validation['falsePositiveClipsPerHourMax'], 2)} |"
                )
            if len(rows) > max_pareto_rows:
                lines.append(
                    f"\n전체 {len(rows)}개 중 {max_pareto_rows}개만 표시했다. JSON 결과에는 모두 포함된다."
                )
            lines.append("")
    lines.extend(
        [
            "## 웃음+박수 동시 감지 진단",
            "",
            "| 모델 | 혼합 샘플 | 웃음 Recall 최저 | 박수 Recall 최저 | 둘 다 감지 최저 |",
            "| --- | ---: | ---: | ---: | ---: |",
        ]
    )
    for model in payload["models"]:
        mixed = model["mixedEventDiagnostic"]
        lines.append(
            f"| {model['model']} | {mixed['sampleCount']} | "
            f"{format_number(mixed['laughterRecallMin'])} | "
            f"{format_number(mixed['clapRecallMin'])} | "
            f"{format_number(mixed['bothDetectedRateMin'])} |"
        )
    lines.extend(
        [
            "",
            "## 해석 제한",
            "",
            "- test를 본 뒤 수행한 사후 튜닝이므로 새로운 일반화 성능으로 주장하지 않는다.",
            "- 아기·어린이·다인·작은 웃음과 거리별 코호트가 없어 해당 요구사항은 미검증이다.",
            "- TV·휴대전화 재생 웃음과 박수의 출처 판별 성능은 미검증이다.",
            "- 추천값은 운영 전환값이 아니라 YAMNet–EfficientAT 섀도 검증 후보이다.",
            "",
        ]
    )
    return "\n".join(lines)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", type=Path, required=True)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument(
        "--required-consecutive-windows",
        type=int,
        action="append",
        dest="consecutive_windows",
    )
    parser.add_argument("--cooldown-seconds", type=float, default=12.0)
    parser.add_argument("--expected-repeats", type=int, default=3)
    parser.add_argument("--max-markdown-pareto-rows", type=int, default=12)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    results_dir = args.results_dir.expanduser().resolve()
    dataset_root = args.dataset_root.expanduser().resolve()
    output_dir = (
        args.output_dir.expanduser().resolve()
        if args.output_dir
        else results_dir / "recall-tuning"
    )
    consecutive_windows = tuple(
        sorted(set(args.consecutive_windows or DEFAULT_CONSECUTIVE_WINDOWS))
    )
    if not results_dir.is_dir() or not (dataset_root / "dataset.json").is_file():
        raise SystemExit("ERROR: results directory or dataset manifest is missing")
    if any(value <= 0 for value in consecutive_windows):
        raise SystemExit("ERROR: required consecutive windows must be positive")
    if args.cooldown_seconds < 0 or args.expected_repeats <= 0:
        raise SystemExit("ERROR: cooldown and repeat values are invalid")
    if args.max_markdown_pareto_rows <= 0:
        raise SystemExit("ERROR: max markdown Pareto rows must be positive")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise SystemExit(f"ERROR: output directory is not empty: {output_dir}")
    try:
        runs_by_model = discover_runs(results_dir, dataset_root)
        comparison_ids = {
            load_summary(run.run_dir / "evaluation-laughter" / "summary.json")
            .get("comparison", {})
            .get("id")
            for runs in runs_by_model.values()
            for run in runs
        }
        if len(comparison_ids) != 1 or None in comparison_ids:
            raise ValueError("runs do not share one comparison ID")
        for model_name, runs in runs_by_model.items():
            if len(runs) != args.expected_repeats:
                raise ValueError(
                    f"{model_name} has {len(runs)} runs, expected {args.expected_repeats}"
                )
        samples_by_event: dict[str, dict[str, DatasetSample]] = {}
        dataset_payload: dict[str, Any] | None = None
        for event_type in EVENT_TYPES:
            payload, samples = load_dataset(
                dataset_root,
                positive_labels=DEFAULT_POSITIVE_LABELS[event_type],
                allow_provisional=False,
            )
            dataset_payload = payload
            samples_by_event[event_type] = samples
    except (json.JSONDecodeError, KeyError, OSError, TypeError, ValueError) as error:
        raise SystemExit(f"ERROR: {error}") from error

    sweep_rows: list[dict[str, Any]] = []
    failure_rows: list[dict[str, Any]] = []
    model_payloads: list[dict[str, Any]] = []
    for model_name in sorted(runs_by_model):
        runs = runs_by_model[model_name]
        event_payloads: dict[str, Any] = {}
        selected_candidates: dict[str, dict[str, Any]] = {}
        for event_type in EVENT_TYPES:
            samples = samples_by_event[event_type]
            validation_samples = [
                sample for sample in samples.values() if sample.split == "validation"
            ]
            test_samples = [sample for sample in samples.values() if sample.split == "test"]
            validation_ids = {sample.sample_id for sample in validation_samples}
            candidates: list[dict[str, Any]] = []
            for consecutive in consecutive_windows:
                for threshold in threshold_candidates(runs, validation_ids, event_type):
                    candidate, _ = evaluate_candidate(
                        runs,
                        validation_samples,
                        event_type=event_type,
                        threshold=threshold,
                        required_consecutive_windows=consecutive,
                    )
                    candidates.append(candidate)
                    sweep_rows.append(
                        {
                            "schemaVersion": SCHEMA_VERSION,
                            "model": model_name,
                            "eventType": event_type,
                            **candidate,
                        }
                    )
            frontier = pareto_frontier(candidates)
            representatives = representative_candidates(candidates, frontier)
            current_candidate, _ = evaluate_candidate(
                runs,
                validation_samples,
                event_type=event_type,
                threshold=runs[0].current_thresholds[event_type],
                required_consecutive_windows=runs[0].current_consecutive_windows,
            )
            enriched: dict[str, Any] = {}
            test_cache: dict[tuple[float, int], tuple[dict[str, Any], list[dict[str, Any]]]] = {}

            def enrich(row: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
                key = (
                    float(row["threshold"]),
                    int(row["requiredConsecutiveWindows"]),
                )
                if key not in test_cache:
                    test_cache[key] = enrich_candidate(
                        row,
                        runs,
                        test_samples,
                        event_type=event_type,
                        cooldown_seconds=args.cooldown_seconds,
                    )
                return test_cache[key]

            enriched["current"] = enrich(current_candidate)[0]
            for name, row in representatives.items():
                enriched[name], failures = enrich(row)
                if name == "shadowCandidate":
                    failure_rows.extend(failures)
                    selected_candidates[event_type] = row
            enriched_frontier = [enrich(row)[0] for row in frontier]
            event_payloads[event_type] = {
                "candidateCount": len(candidates),
                "current": enriched["current"],
                "maximumRecall": enriched["maximumRecall"],
                "maximumF2": enriched["maximumF2"],
                "shadowCandidate": enriched["shadowCandidate"],
                "paretoFrontier": enriched_frontier,
            }
        model_payloads.append(
            {
                "model": model_name,
                "runtime": runs[0].runtime,
                "trialCount": len(runs),
                "streaming": {
                    "windowSeconds": rounded(runs[0].window_seconds, 6),
                    "hopSeconds": rounded(runs[0].hop_seconds, 6),
                    "precision": runs[0].precision,
                },
                "events": event_payloads,
                "mixedEventDiagnostic": mixed_event_diagnostic(
                    runs,
                    samples_by_event["laughter"],
                    selected_candidates["laughter"],
                    selected_candidates["clap"],
                ),
            }
        )

    assert dataset_payload is not None
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "createdAt": utc_now(),
        "comparisonId": next(iter(comparison_ids)),
        "status": "post-hoc-threshold-diagnostic",
        "dataset": {
            "name": dataset_payload.get("name", dataset_root.name),
            "manifestSha256": sha256_file(dataset_root / "dataset.json"),
        },
        "policy": {
            "calibrationSplit": "validation",
            "diagnosticSplit": "test",
            "primaryMetric": "recall",
            "balanceMetric": "f2",
            "paretoObjectives": [
                "maximize-validation-recall-min",
                "minimize-validation-false-positive-clips-per-hour-max",
            ],
            "shadowCandidate": "highest-validation-f2-on-pareto-frontier",
            "cooldownSeconds": args.cooldown_seconds,
            "consecutiveWindowCandidates": list(consecutive_windows),
        },
        "models": model_payloads,
        "limitations": [
            "test is an already-observed post-hoc diagnostic, not a new blind test",
            "baby, child, multiple-person, small-laughter, and distance cohorts are missing",
            "playback-source rejection is not verified",
            "shadow candidates do not authorize production model replacement",
        ],
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    atomic_write_json(output_dir / "threshold-tuning.json", payload)
    (output_dir / "threshold-sweep.jsonl").write_text(
        "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in sweep_rows),
        encoding="utf-8",
    )
    (output_dir / "failure-cases.jsonl").write_text(
        "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in failure_rows),
        encoding="utf-8",
    )
    (output_dir / "threshold-tuning.md").write_text(
        markdown_report(payload, args.max_markdown_pareto_rows),
        encoding="utf-8",
    )
    print(f"PASS: recall-focused audio threshold tuning completed models={len(model_payloads)}")
    print(f"SWEEP_CANDIDATES={len(sweep_rows)}")
    print(f"FAILURE_CASES={len(failure_rows)}")
    print(f"RESULTS_DIR={output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
