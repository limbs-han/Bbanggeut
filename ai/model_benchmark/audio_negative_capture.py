#!/usr/bin/env python3
"""Capture four 15-minute target-free recordings for false-event/hour tests."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import sys
from typing import Sequence

from audio_dataset_capture import capture_preflight, capture_wav
from benchmark_dataset import add_sample, dataset_path, load_dataset


CAPTURE_SECONDS = 15 * 60
SESSION_ID = "office-audio-test-continuous-negative-v1"


@dataclass(frozen=True)
class NegativeScenario:
    slug: str
    conditions: tuple[str, ...]
    instruction: str


SCENARIOS = (
    NegativeScenario(
        "quiet-office",
        ("ambient-noise", "quiet-office"),
        "15분 동안 웃음과 박수 없이 조용한 사무실 상태를 유지합니다.",
    ),
    NegativeScenario(
        "conversation",
        ("conversation", "speech"),
        "15분 동안 웃거나 박수치지 않고 평소처럼 대화합니다.",
    ),
    NegativeScenario(
        "tv-music",
        ("music", "tv-playback"),
        "15분 동안 웃음·박수 장면이 없는 TV 또는 음악을 재생합니다.",
    ),
    NegativeScenario(
        "daily-noise",
        ("daily-noise", "single-impact"),
        "15분 동안 키보드·의자·발걸음과 간헐적인 단발 충격음을 냅니다.",
    ),
)


def registered_ids(root: Path) -> set[str]:
    return {
        row["sampleId"]
        for row in load_dataset(root).get("samples", [])
        if isinstance(row, dict) and isinstance(row.get("sampleId"), str)
    }


def planned_rows() -> list[dict[str, object]]:
    return [
        {
            "sampleId": f"test-continuous-negative-{scenario.slug}-001",
            "conditions": list(scenario.conditions),
            "instruction": scenario.instruction,
            "durationSeconds": CAPTURE_SECONDS,
        }
        for scenario in SCENARIOS
    ]


def capture(root: Path, *, stream_url: str, allow_active_services: bool) -> None:
    if not dataset_path(root).is_file():
        raise ValueError(f"dataset must be initialized first: {dataset_path(root)}")
    capture_preflight(allow_active_services=allow_active_services)
    existing = registered_ids(root)
    media_root = root / "media" / "continuous-negative"
    media_root.mkdir(parents=True, exist_ok=True)
    for number, row in enumerate(planned_rows(), start=1):
        sample_id = str(row["sampleId"])
        if sample_id in existing:
            print(f"SKIP_REGISTERED={sample_id}")
            continue
        destination = media_root / f"{sample_id}.wav"
        if destination.exists():
            raise ValueError(f"unregistered media already exists: {destination}")
        print("\n" + "=" * 68)
        print(f"PROGRESS={number}/{len(SCENARIOS)}")
        print(f"SAMPLE_ID={sample_id}")
        print(f"ACTION={row['instruction']}")
        print("=" * 68)
        choice = input("Enter=15분 녹음, S=건너뛰기, Q=안전 종료: ").strip().lower()
        if choice == "q":
            print("STOPPED_SAFELY=true")
            return
        if choice == "s":
            continue
        capture_wav(stream_url, destination, CAPTURE_SECONDS)
        add_sample(
            root=root,
            sample_id=sample_id,
            media_path=destination,
            split="test",
            conditions=list(row["conditions"]),
            labels=[],
            notes=str(row["instruction"]),
            duration_seconds=float(CAPTURE_SECONDS),
            session_id=SESSION_ID,
        )
        print(f"CAPTURED={sample_id}")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument(
        "--stream-url", default="rtsp://127.0.0.1:8554/homecam/ai"
    )
    parser.add_argument("--allow-active-services", action="store_true")
    parser.add_argument("--print-plan", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if args.print_plan:
        print(json.dumps(planned_rows(), ensure_ascii=False, indent=2))
        return 0
    try:
        capture(
            args.dataset_root.expanduser().resolve(),
            stream_url=args.stream_url,
            allow_active_services=args.allow_active_services,
        )
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
