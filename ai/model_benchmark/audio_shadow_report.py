#!/usr/bin/env python3
"""Compare YAMNet operational decisions with EfficientAT virtual events."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import statistics
from typing import Any, Iterable


SCHEMA_VERSION = "0.1"
EVENT_TYPES = ("LAUGHTER", "CLAP")


def parse_timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as source:
        for line_number, line in enumerate(source, start=1):
            if not line.strip():
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(
                    f"invalid JSONL at {path}:{line_number}"
                ) from error
            if isinstance(payload, dict):
                rows.append(payload)
    return rows


def percentile(values: Iterable[float], ratio: float) -> float | None:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return None
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * ratio
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def latency_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    values = [
        float(row["inferenceMs"])
        for row in rows
        if isinstance(row.get("inferenceMs"), (int, float))
    ]
    return {
        "sampleCount": len(values),
        "meanMs": round(statistics.fmean(values), 3) if values else None,
        "p95Ms": (
            round(percentile(values, 0.95), 3) if values else None
        ),
        "maxMs": round(max(values), 3) if values else None,
    }


def yamnet_events(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for index, row in enumerate(rows):
        detected_at = row.get("observedAt")
        if not isinstance(detected_at, str):
            continue
        if row.get("wouldTrigger") is True:
            events.append(
                {
                    "source": "YAMNet",
                    "sourceRecordIndex": index,
                    "eventType": "LAUGHTER",
                    "detectedAt": detected_at,
                    "confidence": row.get("selectedScore"),
                    "className": row.get("selectedClass"),
                }
            )
        if row.get("clapWouldTrigger") is True:
            events.append(
                {
                    "source": "YAMNet",
                    "sourceRecordIndex": index,
                    "eventType": "CLAP",
                    "detectedAt": detected_at,
                    "confidence": row.get("clapScore"),
                    "className": row.get("clapClass"),
                }
            )
    return events


def shadow_events(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "source": "EfficientAT MN10",
            "sourceRecordIndex": index,
            "virtualEventId": row.get("virtualEventId"),
            "eventType": row.get("eventType"),
            "detectedAt": row.get("detectedAt", row.get("observedAt")),
            "confidence": row.get("confidence"),
            "className": row.get("className"),
        }
        for index, row in enumerate(rows)
        if row.get("recordType") == "virtual-event"
        and row.get("eventType") in EVENT_TYPES
        and isinstance(row.get("detectedAt", row.get("observedAt")), str)
    ]


def match_events(
    operational: list[dict[str, Any]],
    shadow: list[dict[str, Any]],
    tolerance_seconds: float,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    matches: list[dict[str, Any]] = []
    unmatched_shadow = set(range(len(shadow)))
    unmatched_operational: list[dict[str, Any]] = []
    for event in operational:
        event_at = parse_timestamp(event["detectedAt"])
        candidates = [
            (
                abs(
                    (
                        parse_timestamp(shadow[index]["detectedAt"])
                        - event_at
                    ).total_seconds()
                ),
                index,
            )
            for index in unmatched_shadow
            if shadow[index]["eventType"] == event["eventType"]
        ]
        candidates = [row for row in candidates if row[0] <= tolerance_seconds]
        if not candidates:
            unmatched_operational.append(event)
            continue
        gap, index = min(candidates)
        matched_shadow = shadow[index]
        signed_gap = (
            parse_timestamp(matched_shadow["detectedAt"]) - event_at
        ).total_seconds()
        matches.append(
            {
                "eventType": event["eventType"],
                "absoluteGapSeconds": round(gap, 3),
                "efficientAtMinusYamnetSeconds": round(signed_gap, 3),
                "yamnet": event,
                "efficientAt": matched_shadow,
            }
        )
        unmatched_shadow.remove(index)
    return (
        matches,
        unmatched_operational,
        [shadow[index] for index in sorted(unmatched_shadow)],
    )


def duration_hours(rows: list[dict[str, Any]]) -> float | None:
    timestamps = [
        parse_timestamp(row["observedAt"])
        for row in rows
        if isinstance(row.get("observedAt"), str)
    ]
    if len(timestamps) < 2:
        return None
    seconds = (max(timestamps) - min(timestamps)).total_seconds()
    return seconds / 3600.0 if seconds > 0 else None


def compare(
    yamnet_rows: list[dict[str, Any]],
    shadow_rows: list[dict[str, Any]],
    tolerance_seconds: float,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    operational = yamnet_events(yamnet_rows)
    virtual = shadow_events(shadow_rows)
    matches, yamnet_only, efficientat_only = match_events(
        operational,
        virtual,
        tolerance_seconds,
    )
    hours = duration_hours(shadow_rows)
    by_event: dict[str, Any] = {}
    review_rows: list[dict[str, Any]] = []
    for event_type in EVENT_TYPES:
        selected_matches = [
            row for row in matches if row["eventType"] == event_type
        ]
        selected_yamnet = [
            row for row in operational if row["eventType"] == event_type
        ]
        selected_shadow = [
            row for row in virtual if row["eventType"] == event_type
        ]
        selected_yamnet_only = [
            row for row in yamnet_only if row["eventType"] == event_type
        ]
        selected_shadow_only = [
            row for row in efficientat_only if row["eventType"] == event_type
        ]
        by_event[event_type.casefold()] = {
            "yamnetEventCount": len(selected_yamnet),
            "efficientAtVirtualEventCount": len(selected_shadow),
            "matchedEventCount": len(selected_matches),
            "yamnetOnlyCount": len(selected_yamnet_only),
            "efficientAtOnlyCount": len(selected_shadow_only),
            "yamnetMatchRate": (
                round(len(selected_matches) / len(selected_yamnet), 6)
                if selected_yamnet
                else None
            ),
            "efficientAtMatchRate": (
                round(len(selected_matches) / len(selected_shadow), 6)
                if selected_shadow
                else None
            ),
            "efficientAtOnlyPerHour": (
                round(len(selected_shadow_only) / hours, 6)
                if hours
                else None
            ),
        }
        for source, rows in (
            ("yamnet-only", selected_yamnet_only),
            ("efficientat-only", selected_shadow_only),
        ):
            for event in rows:
                review_rows.append(
                    {
                        "schemaVersion": SCHEMA_VERSION,
                        "eventType": event_type,
                        "comparisonStatus": source,
                        "detectedAt": event["detectedAt"],
                        "sourceEvent": event,
                        "groundTruth": None,
                        "reviewStatus": "unreviewed",
                        "reviewNote": None,
                    }
                )

    startup = next(
        (
            row
            for row in shadow_rows
            if row.get("recordType") == "startup"
        ),
        None,
    )
    summary = {
        "schemaVersion": SCHEMA_VERSION,
        "status": "shadow-comparison-needs-manual-review",
        "interpretation": (
            "Model-only events are disagreements, not false positives or false "
            "negatives, until a human assigns ground truth."
        ),
        "configuration": {
            "matchToleranceSeconds": tolerance_seconds,
            "shadowStartup": startup,
        },
        "observation": {
            "durationHours": round(hours, 6) if hours else None,
            "yamnetPredictionCount": sum(
                isinstance(row.get("inferenceMs"), (int, float))
                for row in yamnet_rows
            ),
            "efficientAtPredictionCount": sum(
                row.get("recordType") == "prediction" for row in shadow_rows
            ),
        },
        "latency": {
            "yamnet": latency_summary(yamnet_rows),
            "efficientAt": latency_summary(
                [
                    row
                    for row in shadow_rows
                    if row.get("recordType") == "prediction"
                ]
            ),
        },
        "events": by_event,
        "matches": matches,
        "unreviewedDisagreementCount": len(review_rows),
    }
    return summary, review_rows


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


def markdown_report(summary: dict[str, Any]) -> str:
    lines = [
        "# YAMNet–EfficientAT 섀도 비교",
        "",
        f"상태: `{summary['status']}`",
        "",
        "모델 단독 이벤트는 사람이 정답을 확인하기 전까지 오탐이나 미탐으로 "
        "단정하지 않는다.",
        "",
        "| 이벤트 | YAMNet | EfficientAT 가상 이벤트 | 일치 | YAMNet만 | EfficientAT만 |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for event_type in ("laughter", "clap"):
        row = summary["events"][event_type]
        lines.append(
            f"| {event_type.upper()} | {row['yamnetEventCount']} | "
            f"{row['efficientAtVirtualEventCount']} | {row['matchedEventCount']} | "
            f"{row['yamnetOnlyCount']} | {row['efficientAtOnlyCount']} |"
        )
    lines.extend(
        [
            "",
            "## 추론 지연",
            "",
            "| 모델 | 표본 | 평균(ms) | P95(ms) | 최대(ms) |",
            "|---|---:|---:|---:|---:|",
        ]
    )
    for key, name in (("yamnet", "YAMNet"), ("efficientAt", "EfficientAT")):
        row = summary["latency"][key]
        lines.append(
            f"| {name} | {row['sampleCount']} | {row['meanMs']} | "
            f"{row['p95Ms']} | {row['maxMs']} |"
        )
    lines.extend(
        [
            "",
            "## 다음 판정",
            "",
            "- 불일치 항목에 사람이 `groundTruth`를 기록한다.",
            "- 검수 후에만 Recall, Precision, 오탐/시간을 계산한다.",
            "- 검수 전 결과만으로 운영 모델을 교체하지 않는다.",
            "",
        ]
    )
    return "\n".join(lines)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--yamnet-diagnostics", type=Path, required=True)
    parser.add_argument("--shadow-diagnostics", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--match-tolerance-seconds", type=float, default=12.0)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.match_tolerance_seconds < 0:
        raise SystemExit("--match-tolerance-seconds cannot be negative")
    yamnet_path = args.yamnet_diagnostics.expanduser().resolve()
    shadow_path = args.shadow_diagnostics.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    summary, review_rows = compare(
        load_jsonl(yamnet_path),
        load_jsonl(shadow_path),
        args.match_tolerance_seconds,
    )
    atomic_write(
        output_dir / "summary.json",
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
    )
    atomic_write(output_dir / "summary.md", markdown_report(summary))
    atomic_write(
        output_dir / "manual-review.jsonl",
        "".join(
            json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n"
            for row in review_rows
        ),
    )
    print(f"STATUS={summary['status']}")
    print(f"DISAGREEMENTS={len(review_rows)}")
    print(f"RESULTS_DIR={output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
