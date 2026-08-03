#!/usr/bin/env python3
"""Aggregate repeated laughter/clap benchmarks into presentation artifacts."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import statistics
from typing import Any, Iterable, Sequence


EXPECTED_MODELS = ("YAMNet", "EfficientAT MN10", "PANNs CNN10")
EVENT_TYPES = ("laughter", "clap")


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def nested_number(payload: dict[str, Any], *keys: str) -> float | None:
    value: Any = payload
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return float(value) if isinstance(value, (int, float)) else None


def mean(values: Iterable[float | None]) -> float | None:
    selected = [value for value in values if value is not None]
    return round(statistics.fmean(selected), 6) if selected else None


def maximum(values: Iterable[float | None]) -> float | None:
    selected = [value for value in values if value is not None]
    return round(max(selected), 6) if selected else None


def minimum(values: Iterable[float | None]) -> float | None:
    selected = [value for value in values if value is not None]
    return round(min(selected), 6) if selected else None


def standard_deviation(values: Iterable[float | None]) -> float | None:
    selected = [value for value in values if value is not None]
    return round(statistics.pstdev(selected), 6) if selected else None


def load_summaries(results_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(results_dir.glob("**/summary.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict) or payload.get("component") != "audio":
            continue
        event_type = payload.get("accuracy", {}).get("eventType")
        if event_type not in EVENT_TYPES:
            continue
        payload["_path"] = str(path)
        rows.append(payload)
    if not rows:
        raise ValueError("no laughter/clap audio summary.json files were found")
    return rows


def ensure_same(rows: list[dict[str, Any]], getter: Any, label: str) -> Any:
    values = {json.dumps(getter(row), sort_keys=True) for row in rows}
    if len(values) != 1:
        raise ValueError(f"runs do not share the same {label}")
    return getter(rows[0])


def aggregate_event(rows: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "trialCount": len(rows),
        "f1Mean": mean(
            nested_number(row, "accuracy", "operatingPoint", "f1") for row in rows
        ),
        "f1Std": standard_deviation(
            nested_number(row, "accuracy", "operatingPoint", "f1") for row in rows
        ),
        "precisionMean": mean(
            nested_number(row, "accuracy", "operatingPoint", "precision")
            for row in rows
        ),
        "recallMean": mean(
            nested_number(row, "accuracy", "operatingPoint", "recall")
            for row in rows
        ),
        "recallMin": minimum(
            nested_number(row, "accuracy", "operatingPoint", "recall")
            for row in rows
        ),
        "falsePositivesPerHourMean": mean(
            nested_number(
                row, "accuracy", "operatingPoint", "falsePositivesPerHour"
            )
            for row in rows
        ),
        "falsePositivesPerHourMax": maximum(
            nested_number(
                row, "accuracy", "operatingPoint", "falsePositivesPerHour"
            )
            for row in rows
        ),
        "thresholdMean": mean(
            nested_number(row, "accuracy", "operatingPoint", "threshold")
            for row in rows
        ),
        "falseEventCountMax": maximum(
            nested_number(row, "accuracy", "operatingPoint", "falseEventCount")
            for row in rows
        ),
        "failureCases": sum(
            len(row.get("accuracy", {}).get("failureCases", [])) for row in rows
        ),
        "runs": [
            {
                "runId": row.get("runId"),
                "trialIndex": row.get("comparison", {}).get("trialIndex"),
                "executionOrder": row.get("comparison", {}).get("executionOrder"),
                "summary": row["_path"],
            }
            for row in rows
        ],
    }


def aggregate_model(
    name: str,
    event_rows: dict[str, list[dict[str, Any]]],
    *,
    minimum_recall: float,
    maximum_fp_per_hour: float,
) -> dict[str, Any]:
    events = {
        event_type: aggregate_event(event_rows[event_type])
        for event_type in EVENT_TYPES
    }
    all_rows = [row for rows in event_rows.values() for row in rows]
    recalls = [events[event_type]["recallMin"] for event_type in EVENT_TYPES]
    false_rates = [
        events[event_type]["falsePositivesPerHourMax"] for event_type in EVENT_TYPES
    ]
    recall_gate = all(
        value is not None and value >= minimum_recall for value in recalls
    )
    fp_gate = all(
        value is not None and value <= maximum_fp_per_hour for value in false_rates
    )
    return {
        "model": name,
        "events": events,
        "combined": {
            "macroF1Mean": mean(
                events[event_type]["f1Mean"] for event_type in EVENT_TYPES
            ),
            "minimumRecallMean": minimum(recalls),
            "maximumFalsePositivesPerHourMean": maximum(false_rates),
        },
        "performance": {
            "inferenceMeanMs": mean(
                nested_number(row, "metrics", "inferenceMeanMs") for row in all_rows
            ),
            "inferenceP95MsMean": mean(
                nested_number(row, "metrics", "inferenceP95Ms") for row in all_rows
            ),
            "inferenceP95MsMax": maximum(
                nested_number(row, "metrics", "inferenceP95Ms") for row in all_rows
            ),
        },
        "resources": {
            "gpuPercentMax": maximum(
                nested_number(row, "resources", "gpuPercentMax") for row in all_rows
            ),
            "ramUsedMbMax": maximum(
                nested_number(row, "resources", "ramUsedMbMax") for row in all_rows
            ),
            "temperatureCMax": maximum(
                nested_number(row, "resources", "temperatureCMax") for row in all_rows
            ),
            "powerMwMax": maximum(
                nested_number(row, "resources", "powerMwMax") for row in all_rows
            ),
        },
        "serviceGates": {
            "minimumRecall": minimum_recall,
            "maximumFalsePositivesPerHour": maximum_fp_per_hour,
            "recallPass": recall_gate,
            "falsePositiveRatePass": fp_gate,
            "eligible": recall_gate and fp_gate,
        },
    }


def rank_key(row: dict[str, Any]) -> tuple[float, float, float, float, float]:
    combined = row["combined"]
    latency = row["performance"]["inferenceP95MsMean"]
    return (
        -float(row["serviceGates"]["eligible"]),
        combined["maximumFalsePositivesPerHourMean"]
        if combined["maximumFalsePositivesPerHourMean"] is not None
        else float("inf"),
        -(combined["macroF1Mean"] if combined["macroF1Mean"] is not None else -1),
        -(
            combined["minimumRecallMean"]
            if combined["minimumRecallMean"] is not None
            else -1
        ),
        latency if latency is not None else float("inf"),
    )


def format_value(value: Any, digits: int = 3) -> str:
    return "N/A" if value is None else f"{float(value):.{digits}f}"


def markdown_report(payload: dict[str, Any]) -> str:
    lines = [
        "# 웃음·연속 박수 탐지 모델 비교 결과",
        "",
        f"- 비교 ID: `{payload['comparisonId']}`",
        f"- 데이터셋: `{payload['dataset']['name']}`",
        f"- 반복 횟수: 모델당 {payload['expectedRepeats']}회",
        "- 임계값은 validation에서만 결정하고 test에는 고정했다.",
        "- 선택 우선순위는 오탐 억제, Recall 기준 충족, Macro F1, 지연시간 순이다.",
        "",
        "## 모델별 핵심 지표",
        "",
        "| 모델 | 웃음 F1 | 웃음 Recall | 웃음 FP/h | 박수 F1 | 박수 Recall | 박수 FP/h | Macro F1 | P95 ms | 판정 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for row in payload["models"]:
        laughter = row["events"]["laughter"]
        clap = row["events"]["clap"]
        lines.append(
            "| {model} | {lf1} | {lr} | {lfp} | {cf1} | {cr} | {cfp} | {macro} | {p95} | {gate} |".format(
                model=row["model"],
                lf1=format_value(laughter["f1Mean"]),
                lr=format_value(laughter["recallMean"]),
                lfp=format_value(laughter["falsePositivesPerHourMean"], 2),
                cf1=format_value(clap["f1Mean"]),
                cr=format_value(clap["recallMean"]),
                cfp=format_value(clap["falsePositivesPerHourMean"], 2),
                macro=format_value(row["combined"]["macroF1Mean"]),
                p95=format_value(row["performance"]["inferenceP95MsMean"], 2),
                gate="통과" if row["serviceGates"]["eligible"] else "미달",
            )
        )
    selection = payload["selection"]
    lines.extend(
        [
            "",
            "## 결론",
            "",
            f"- 종합 순위: {', '.join(payload['rankings']['serviceFit'])}",
            f"- 추천 상태: `{selection['status']}`",
            f"- 추천 모델: `{selection['selectedModel'] or '없음'}`",
            f"- 근거: {selection['reason']}",
            "- 최종 운영 전에는 YOLOv8n TensorRT FP16 동시 실행과 앱 이벤트 종단 검증을 추가로 통과해야 한다.",
            "",
        ]
    )
    return "\n".join(lines)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--expected-repeats", type=int, default=3)
    parser.add_argument("--minimum-recall", type=float, default=0.85)
    parser.add_argument("--maximum-fp-per-hour", type=float, default=1.0)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    results_dir = args.results_dir.expanduser().resolve()
    output_dir = (
        args.output_dir.expanduser().resolve()
        if args.output_dir
        else results_dir / "report"
    )
    if args.expected_repeats < 1:
        raise SystemExit("ERROR: expected repeats must be positive")
    if not 0 <= args.minimum_recall <= 1 or args.maximum_fp_per_hour < 0:
        raise SystemExit("ERROR: service gate values are invalid")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise SystemExit(f"ERROR: output directory is not empty: {output_dir}")

    try:
        summaries = load_summaries(results_dir)
        comparison_id = ensure_same(
            summaries,
            lambda row: row.get("comparison", {}).get("id"),
            "comparison ID",
        )
        dataset_name = ensure_same(
            summaries,
            lambda row: row.get("dataset", {}).get("name"),
            "dataset name",
        )
        dataset_hash = ensure_same(
            summaries,
            lambda row: row.get("dataset", {}).get("manifestSha256"),
            "dataset checksum",
        )
        grouped: dict[str, dict[str, list[dict[str, Any]]]] = {
            model: {
                event_type: [
                    row
                    for row in summaries
                    if row.get("model", {}).get("name") == model
                    and row.get("accuracy", {}).get("eventType") == event_type
                ]
                for event_type in EVENT_TYPES
            }
            for model in EXPECTED_MODELS
        }
        for model, events in grouped.items():
            for event_type, rows in events.items():
                if len(rows) != args.expected_repeats:
                    raise ValueError(
                        f"{model}/{event_type} has {len(rows)} runs; "
                        f"expected {args.expected_repeats}"
                    )
        models = [
            aggregate_model(
                model,
                grouped[model],
                minimum_recall=args.minimum_recall,
                maximum_fp_per_hour=args.maximum_fp_per_hour,
            )
            for model in EXPECTED_MODELS
        ]
    except (json.JSONDecodeError, OSError, ValueError) as error:
        raise SystemExit(f"ERROR: {error}") from error

    ranked = sorted(models, key=rank_key)
    eligible = [row for row in ranked if row["serviceGates"]["eligible"]]
    selected = eligible[0]["model"] if eligible else None
    payload = {
        "schemaVersion": "0.2",
        "createdAt": utc_now(),
        "comparisonId": comparison_id,
        "expectedRepeats": args.expected_repeats,
        "dataset": {"name": dataset_name, "manifestSha256": dataset_hash},
        "selectionPolicy": {
            "minimumRecall": args.minimum_recall,
            "maximumFalsePositivesPerHour": args.maximum_fp_per_hour,
            "priority": [
                "service-gates",
                "false-positives-per-hour",
                "macro-f1",
                "minimum-recall",
                "p95-latency",
            ],
        },
        "models": models,
        "rankings": {"serviceFit": [row["model"] for row in ranked]},
        "selection": {
            "status": "recommended-pending-concurrent-e2e" if selected else "no-model-passed-gates",
            "selectedModel": selected,
            "reason": (
                "Both event recalls and false-event/hour gates passed; concurrent YOLO and app E2E remain."
                if selected
                else "No model passed both the recall and false-event/hour gates."
            ),
        },
    }

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "comparison.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (output_dir / "comparison.md").write_text(
        markdown_report(payload), encoding="utf-8"
    )
    with (output_dir / "comparison.csv").open(
        "w", encoding="utf-8-sig", newline=""
    ) as destination:
        writer = csv.writer(destination)
        writer.writerow(
            [
                "model",
                "event_type",
                "trials",
                "f1_mean",
                "precision_mean",
                "recall_mean",
                "false_events_per_hour_mean",
                "threshold_mean",
                "inference_p95_ms_mean",
                "gpu_percent_max",
                "ram_used_mb_max",
                "service_gate_pass",
            ]
        )
        for row in models:
            for event_type in EVENT_TYPES:
                event = row["events"][event_type]
                writer.writerow(
                    [
                        row["model"],
                        event_type,
                        event["trialCount"],
                        event["f1Mean"],
                        event["precisionMean"],
                        event["recallMean"],
                        event["falsePositivesPerHourMean"],
                        event["thresholdMean"],
                        row["performance"]["inferenceP95MsMean"],
                        row["resources"]["gpuPercentMax"],
                        row["resources"]["ramUsedMbMax"],
                        row["serviceGates"]["eligible"],
                    ]
                )
    print(f"PASS: dual-event audio comparison report created models={len(models)}")
    print(f"REPORT_DIR={output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
