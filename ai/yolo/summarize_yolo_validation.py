#!/usr/bin/env python3
"""Summarize one Jetson YOLO RTSP validation run.

The detector writes a framing command every few hundred milliseconds. This
tool turns that JSONL evidence and the process log into a small Markdown/JSON
report without requiring Ultralytics, OpenCV, or other model dependencies.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any


TARGET_CLASSES = ("person", "cat", "dog")
FPS_PATTERN = re.compile(r"\bfps=(\d+(?:\.\d+)?)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commands", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--tested-classes",
        default="person,cat,dog",
        help=(
            "Comma-separated target classes intentionally presented during "
            "the run. Missing classes are reported as NOT TESTED."
        ),
    )
    return parser.parse_args()


def load_commands(path: Path) -> tuple[list[dict[str, Any]], int]:
    commands: list[dict[str, Any]] = []
    invalid_lines = 0
    with path.open(encoding="utf-8") as source:
        for raw_line in source:
            line = raw_line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                invalid_lines += 1
                continue
            if not isinstance(payload, dict):
                invalid_lines += 1
                continue
            commands.append(payload)
    return commands, invalid_lines


def after_tracking_states(commands: list[dict[str, Any]]) -> tuple[bool, bool]:
    seen_tracking = False
    hold_after_tracking = False
    home_after_tracking = False
    for command in commands:
        state = str(command.get("state", "UNKNOWN")).upper()
        direction = str(command.get("direction", "UNKNOWN")).upper()
        if state == "TRACKING":
            seen_tracking = True
        elif seen_tracking and (
            state in {"HOLD", "NO_TARGET_HOLD"} or direction == "HOLD"
        ):
            hold_after_tracking = True
        elif seen_tracking and (
            state in {"HOME", "RETURN_HOME"} or direction == "HOME"
        ):
            home_after_tracking = True
    return hold_after_tracking, home_after_tracking


def summarize(
    commands: list[dict[str, Any]],
    invalid_lines: int,
    log_text: str,
    tested_classes: set[str] | None = None,
) -> dict[str, Any]:
    if tested_classes is None:
        tested_classes = set(TARGET_CLASSES)
    state_counts: Counter[str] = Counter()
    direction_counts: Counter[str] = Counter()
    samples_with_class: Counter[str] = Counter()
    maximum_object_counts: Counter[str] = Counter()
    unique_track_ids: set[int] = set()

    for command in commands:
        state_counts[str(command.get("state", "UNKNOWN")).upper()] += 1
        direction_counts[str(command.get("direction", "UNKNOWN")).upper()] += 1

        object_counts = command.get("object_counts", {})
        if isinstance(object_counts, dict):
            for class_name in TARGET_CLASSES:
                try:
                    count = int(object_counts.get(class_name, 0))
                except (TypeError, ValueError):
                    count = 0
                maximum_object_counts[class_name] = max(
                    maximum_object_counts[class_name],
                    count,
                )
                if count > 0:
                    samples_with_class[class_name] += 1

        track_ids = command.get("track_ids", command.get("target_ids", []))
        if isinstance(track_ids, list):
            for track_id in track_ids:
                try:
                    unique_track_ids.add(int(track_id))
                except (TypeError, ValueError):
                    continue

    fps_values = [float(match) for match in FPS_PATTERN.findall(log_text)]
    hold_after_tracking, home_after_tracking = after_tracking_states(commands)
    first_command_at = (
        commands[0].get("sent_at", commands[0].get("created_at"))
        if commands
        else None
    )
    last_command_at = (
        commands[-1].get("sent_at", commands[-1].get("created_at"))
        if commands
        else None
    )

    return {
        "command_samples": len(commands),
        "invalid_jsonl_lines": invalid_lines,
        "first_command_at": first_command_at,
        "last_command_at": last_command_at,
        "state_counts": dict(sorted(state_counts.items())),
        "direction_counts": dict(sorted(direction_counts.items())),
        "maximum_object_counts": {
            class_name: maximum_object_counts[class_name]
            for class_name in TARGET_CLASSES
        },
        "samples_with_class": {
            class_name: samples_with_class[class_name]
            for class_name in TARGET_CLASSES
        },
        "tested_classes": sorted(tested_classes),
        "unique_track_ids": sorted(unique_track_ids),
        "observed_tracking": state_counts["TRACKING"] > 0,
        "observed_hold_after_tracking": hold_after_tracking,
        "observed_home_after_tracking": home_after_tracking,
        "stream_connected_messages": (
            log_text.count("Video stream connected:")
            + len(re.findall(r"(?m)^Source:\s+rtsp://", log_text))
        ),
        "stream_unavailable_messages": log_text.count("Video stream unavailable"),
        "stream_reconnected_messages": log_text.count("Video stream reconnected:"),
        "reported_fps_mean": (
            round(sum(fps_values) / len(fps_values), 3) if fps_values else None
        ),
        "reported_fps_last": fps_values[-1] if fps_values else None,
    }


def result_label(value: bool) -> str:
    return "PASS" if value else "NOT OBSERVED"


def class_result(
    class_name: str,
    detected: bool,
    tested_classes: set[str],
) -> str:
    if detected:
        return "PASS"
    if class_name not in tested_classes:
        return "NOT TESTED"
    return "NOT OBSERVED"


def reconnect_label(summary: dict[str, Any]) -> str:
    unavailable = int(summary["stream_unavailable_messages"])
    reconnected = int(summary["stream_reconnected_messages"])
    if unavailable == 0:
        return "NOT TESTED"
    return "PASS" if reconnected > 0 else "NOT OBSERVED"


def markdown_report(summary: dict[str, Any]) -> str:
    maximum_counts = summary["maximum_object_counts"]
    samples_with_class = summary["samples_with_class"]
    tested_classes = set(summary["tested_classes"])
    rows = [
        "# YOLO RTSP validation summary",
        "",
        "> `NOT OBSERVED` means the evidence was not present in this run. "
        "It does not by itself prove that the implementation is defective.",
        "",
        "## Run evidence",
        "",
        "| Item | Result |",
        "| --- | ---: |",
        f"| Command samples | {summary['command_samples']} |",
        f"| Invalid JSONL lines | {summary['invalid_jsonl_lines']} |",
        f"| First command | {summary['first_command_at'] or '-'} |",
        f"| Last command | {summary['last_command_at'] or '-'} |",
        f"| Mean reported FPS | {summary['reported_fps_mean'] or '-'} |",
        f"| Last reported FPS | {summary['reported_fps_last'] or '-'} |",
        f"| Unique track IDs | {summary['unique_track_ids']} |",
        "",
        "## Target classes",
        "",
        "| Class | Result | Maximum simultaneous | Samples detected |",
        "| --- | --- | ---: | ---: |",
    ]
    for class_name in TARGET_CLASSES:
        detected = maximum_counts[class_name] > 0
        rows.append(
            f"| {class_name} | "
            f"{class_result(class_name, detected, tested_classes)} | "
            f"{maximum_counts[class_name]} | {samples_with_class[class_name]} |"
        )

    rows.extend(
        [
            "",
            "## Framing states",
            "",
            "| Check | Result |",
            "| --- | --- |",
            (
                "| TRACKING observed | "
                f"{result_label(bool(summary['observed_tracking']))} |"
            ),
            (
                "| HOLD after tracking | "
                f"{result_label(bool(summary['observed_hold_after_tracking']))} |"
            ),
            (
                "| HOME after tracking | "
                f"{result_label(bool(summary['observed_home_after_tracking']))} |"
            ),
            f"| State sample counts | `{summary['state_counts']}` |",
            f"| Direction sample counts | `{summary['direction_counts']}` |",
            "",
            "## Stream",
            "",
            "| Check | Result |",
            "| --- | --- |",
            (
                "| Initial RTSP connection | "
                f"{result_label(summary['stream_connected_messages'] > 0)} |"
            ),
            f"| Forced interruption and reconnect | {reconnect_label(summary)} |",
            (
                "| Unavailable/reconnected messages | "
                f"{summary['stream_unavailable_messages']} / "
                f"{summary['stream_reconnected_messages']} |"
            ),
            "",
            "Review the annotated MP4 to confirm class labels, boxes, target "
            "selection, and visible tracking continuity.",
            "",
        ]
    )
    return "\n".join(rows)


def main() -> None:
    args = parse_args()
    commands_path = args.commands.expanduser().resolve()
    log_path = args.log.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()

    if not commands_path.is_file():
        raise SystemExit(f"Command JSONL not found: {commands_path}")
    if not log_path.is_file():
        raise SystemExit(f"YOLO log not found: {log_path}")

    commands, invalid_lines = load_commands(commands_path)
    if not commands:
        raise SystemExit(f"No valid command samples found: {commands_path}")

    tested_classes = {
        value.strip().casefold()
        for value in args.tested_classes.split(",")
        if value.strip()
    }
    unknown_classes = tested_classes.difference(TARGET_CLASSES)
    if unknown_classes:
        raise SystemExit(
            "Unknown --tested-classes values: "
            + ", ".join(sorted(unknown_classes))
        )

    summary = summarize(
        commands,
        invalid_lines,
        log_path.read_text(encoding="utf-8", errors="replace"),
        tested_classes,
    )
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "summary.json"
    markdown_path = output_dir / "summary.md"
    json_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    markdown_path.write_text(markdown_report(summary), encoding="utf-8")
    print(markdown_report(summary))
    print(f"JSON summary: {json_path}")
    print(f"Markdown summary: {markdown_path}")


if __name__ == "__main__":
    main()
