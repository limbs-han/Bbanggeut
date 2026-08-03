#!/usr/bin/env python3
"""Plan and capture the local audio-event benchmark dataset on Jetson."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import subprocess
import sys
import time
from typing import Any, Sequence

from benchmark_dataset import (
    add_sample,
    create_dataset,
    dataset_path,
    load_dataset,
    review_sample,
    utc_now,
)


SCHEMA_VERSION = "0.1"
DEFAULT_STREAM_URL = "rtsp://127.0.0.1:8554/homecam/ai"
CAPTURE_SECONDS = 10
SAMPLE_RATE = 48_000
SAMPLES_PER_CONDITION = 10
SPLITS = ("validation", "test")


@dataclass(frozen=True)
class Scenario:
    slug: str
    labels: tuple[str, ...]
    conditions: tuple[str, ...]
    instructions: tuple[str, ...]


SCENARIOS = (
    Scenario(
        "laughter-only",
        ("laughter",),
        ("laughter",),
        (
            "한 명이 자연스럽고 분명하게 웃습니다.",
            "두 명이 번갈아 자연스럽게 웃습니다.",
            "두세 명이 함께 자연스럽게 웃습니다.",
        ),
    ),
    Scenario(
        "consecutive-clap",
        ("clap",),
        ("consecutive-clap",),
        (
            "박수를 0.25~0.5초 간격으로 6~10번 칩니다.",
            "카메라에서 약간 떨어져 박수를 6~10번 칩니다.",
            "두 사람이 번갈아 연속 박수를 칩니다.",
        ),
    ),
    Scenario(
        "laughter-with-clap",
        ("clap", "laughter"),
        ("laughter-with-clap",),
        (
            "먼저 웃고 2초 안에 연속 박수를 칩니다.",
            "먼저 연속 박수를 치고 2초 안에 웃습니다.",
            "한 사람은 웃고 다른 사람은 연속 박수를 칩니다.",
        ),
    ),
    Scenario(
        "conversation",
        (),
        ("conversation", "speech"),
        (
            "한 명이 평소 음량으로 대화하듯 말합니다.",
            "두 명이 서로 자연스럽게 대화합니다.",
            "세 명이 웃지 않고 자연스럽게 대화합니다.",
        ),
    ),
    Scenario(
        "single-impact",
        (),
        ("single-impact",),
        (
            "박수를 정확히 한 번만 칩니다.",
            "책상이나 물건을 한 번만 가볍게 두드립니다.",
            "문을 한 번 닫거나 비슷한 단발 충격음을 냅니다.",
        ),
    ),
    Scenario(
        "background-noise",
        (),
        ("ambient-noise", "daily-noise"),
        (
            "TV 소리를 재생하되 웃음이나 박수 장면은 피합니다.",
            "음악을 재생합니다.",
            "키보드·의자·발걸음 등 일상 소음을 냅니다.",
        ),
    ),
)


def plan_path(root: Path) -> Path:
    return root / "capture-plan.json"


def make_plan(dataset_name: str) -> dict[str, Any]:
    samples: list[dict[str, Any]] = []
    for split in SPLITS:
        session_id = f"office-audio-{split}-v1"
        for scenario in SCENARIOS:
            for index in range(1, SAMPLES_PER_CONDITION + 1):
                conditions = list(scenario.conditions)
                if scenario.slug == "background-noise":
                    conditions.append(
                        ("tv-playback", "music", "daily-noise")[(index - 1) % 3]
                    )
                samples.append(
                    {
                        "sampleId": f"{split}-{scenario.slug}-{index:03d}",
                        "split": split,
                        "scenario": scenario.slug,
                        "labels": list(scenario.labels),
                        "conditions": sorted(set(conditions)),
                        "sessionId": session_id,
                        "durationSeconds": CAPTURE_SECONDS,
                        "instruction": scenario.instructions[
                            (index - 1) % len(scenario.instructions)
                        ],
                    }
                )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "dataset": dataset_name,
        "createdAt": utc_now(),
        "capture": {
            "format": "PCM_S16LE",
            "channels": 1,
            "sampleRate": SAMPLE_RATE,
            "durationSeconds": CAPTURE_SECONDS,
            "devicePositionMustRemainFixed": True,
            "validationAndTestMustUseDifferentTakes": True,
        },
        "samples": samples,
    }


def write_plan(root: Path, payload: dict[str, Any]) -> None:
    path = plan_path(root)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def load_plan(root: Path) -> dict[str, Any]:
    path = plan_path(root)
    if not path.is_file():
        raise ValueError(f"capture plan does not exist: {path}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or not isinstance(payload.get("samples"), list):
        raise ValueError("capture plan must contain a samples array")
    return payload


def service_state(name: str) -> str:
    completed = subprocess.run(
        ["systemctl", "is-active", name],
        check=False,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def capture_preflight(*, allow_active_services: bool) -> None:
    required = ("wj-mediamtx-local", "wj-media-source")
    competing = ("wj-device-agent", "wj-local-recording", "wj-edge-ai-recording")
    missing = [name for name in required if service_state(name) != "active"]
    if missing:
        raise ValueError("required local media services are not active: " + ", ".join(missing))
    active = [name for name in competing if service_state(name) == "active"]
    if active and not allow_active_services:
        raise ValueError(
            "stop app streaming, recording, and event upload services first: "
            + ", ".join(active)
        )


def build_capture_command(
    stream_url: str,
    temporary: Path,
    duration_seconds: int,
) -> list[str]:
    expected_samples = SAMPLE_RATE * duration_seconds
    audio_filter = (
        f"aresample={SAMPLE_RATE},"
        "asetpts=N/SR/TB,"
        f"apad=whole_len={expected_samples},"
        f"atrim=end_sample={expected_samples},"
        "asetpts=N/SR/TB"
    )
    return [
        "/usr/bin/ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "warning",
        "-y",
        "-rtsp_transport",
        "tcp",
        "-i",
        stream_url,
        "-map",
        "0:a:0",
        "-vn",
        "-af",
        audio_filter,
        "-t",
        str(duration_seconds),
        "-ac",
        "1",
        "-ar",
        str(SAMPLE_RATE),
        "-c:a",
        "pcm_s16le",
        "-f",
        "wav",
        str(temporary),
    ]


def capture_wav(stream_url: str, destination: Path, duration_seconds: int) -> None:
    temporary = destination.with_suffix(".wav.tmp")
    command = build_capture_command(stream_url, temporary, duration_seconds)
    try:
        completed = subprocess.run(
            command,
            check=False,
            timeout=duration_seconds + 30,
        )
    except subprocess.TimeoutExpired as error:
        temporary.unlink(missing_ok=True)
        raise ValueError("ffmpeg audio capture timed out") from error
    if completed.returncode != 0 or not temporary.is_file() or temporary.stat().st_size == 0:
        temporary.unlink(missing_ok=True)
        raise ValueError(f"ffmpeg audio capture failed with status {completed.returncode}")
    temporary.replace(destination)

    probe = subprocess.run(
        [
            "/usr/bin/ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=sample_rate,channels:format=duration",
            "-of",
            "json",
            str(destination),
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
    )
    if probe.returncode != 0:
        destination.unlink(missing_ok=True)
        raise ValueError("ffprobe could not validate the captured WAV")
    try:
        metadata = json.loads(probe.stdout)
        stream = metadata["streams"][0]
        actual_duration = float(metadata["format"]["duration"])
        actual_rate = int(stream["sample_rate"])
        actual_channels = int(stream["channels"])
    except (IndexError, KeyError, TypeError, ValueError) as error:
        destination.unlink(missing_ok=True)
        raise ValueError("captured WAV metadata is incomplete") from error
    tolerance = max(1.0, duration_seconds * 0.01)
    if (
        abs(actual_duration - duration_seconds) > tolerance
        or actual_rate != SAMPLE_RATE
        or actual_channels != 1
    ):
        destination.unlink(missing_ok=True)
        raise ValueError(
            "captured WAV does not match duration, 48 kHz, and mono requirements: "
            f"duration={actual_duration:.3f}s rate={actual_rate} channels={actual_channels}"
        )


def registered_sample_ids(root: Path) -> set[str]:
    return {
        row["sampleId"]
        for row in load_dataset(root).get("samples", [])
        if isinstance(row, dict) and isinstance(row.get("sampleId"), str)
    }


def initialize(root: Path, name: str) -> None:
    if not dataset_path(root).exists():
        create_dataset(root, name)
    if plan_path(root).exists():
        raise ValueError(f"capture plan already exists: {plan_path(root)}")
    root.joinpath("media").mkdir(parents=True, exist_ok=True)
    write_plan(root, make_plan(name))


def capture_split(
    root: Path,
    *,
    split: str,
    stream_url: str,
    allow_active_services: bool,
) -> None:
    capture_preflight(allow_active_services=allow_active_services)
    payload = load_plan(root)
    registered = registered_sample_ids(root)
    rows = [row for row in payload["samples"] if row.get("split") == split]
    if len(rows) != 60:
        raise ValueError(f"expected 60 planned {split} samples, found {len(rows)}")
    for number, row in enumerate(rows, start=1):
        sample_id = row["sampleId"]
        if sample_id in registered:
            print(f"SKIP_REGISTERED={sample_id}")
            continue
        destination = root / "media" / f"{sample_id}.wav"
        if destination.exists():
            raise ValueError(f"unregistered media already exists: {destination}")
        print("\n" + "=" * 68)
        print(f"PROGRESS={number}/{len(rows)}")
        print(f"SAMPLE_ID={sample_id}")
        print(f"SCENARIO={row['scenario']}")
        print(f"ACTION={row['instruction']}")
        print("=" * 68)
        choice = input("Enter=녹음, S=건너뛰기, Q=안전 종료: ").strip().lower()
        if choice == "q":
            print("STOPPED_SAFELY=true")
            return
        if choice == "s":
            continue
        for remaining in (3, 2, 1):
            print(remaining, flush=True)
            time.sleep(1)
        print("RECORDING_START", flush=True)
        capture_wav(stream_url, destination, int(row["durationSeconds"]))
        sample = add_sample(
            root=root,
            sample_id=sample_id,
            media_path=destination,
            split=split,
            conditions=list(row["conditions"]),
            labels=list(row["labels"]),
            notes=row["instruction"],
            duration_seconds=float(row["durationSeconds"]),
            session_id=row["sessionId"],
        )
        print(f"CAPTURED={sample['sampleId']} bytes={sample['sizeBytes']}")


def verify_plan(root: Path) -> None:
    plan = load_plan(root)
    rows = plan["samples"]
    if len(rows) != 120:
        raise ValueError(f"expected 120 planned samples, found {len(rows)}")
    seen: set[str] = set()
    for row in rows:
        sample_id = row.get("sampleId")
        if not isinstance(sample_id, str) or sample_id in seen:
            raise ValueError(f"invalid or duplicate planned sample: {sample_id!r}")
        seen.add(sample_id)
    for split in SPLITS:
        split_rows = [row for row in rows if row.get("split") == split]
        if len(split_rows) != 60:
            raise ValueError(f"{split} must contain 60 samples")
        for scenario in SCENARIOS:
            count = sum(row.get("scenario") == scenario.slug for row in split_rows)
            if count != SAMPLES_PER_CONDITION:
                raise ValueError(f"{split}/{scenario.slug} must contain 10 samples")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init")
    init_parser.add_argument("--dataset-root", type=Path, required=True)
    init_parser.add_argument("--name", default="office-audio-events-v1")

    capture_parser = subparsers.add_parser("capture")
    capture_parser.add_argument("--dataset-root", type=Path, required=True)
    capture_parser.add_argument("--split", choices=SPLITS, required=True)
    capture_parser.add_argument("--stream-url", default=DEFAULT_STREAM_URL)
    capture_parser.add_argument("--allow-active-services", action="store_true")

    verify_parser = subparsers.add_parser("verify-plan")
    verify_parser.add_argument("--dataset-root", type=Path, required=True)

    review_parser = subparsers.add_parser("review")
    review_parser.add_argument("--dataset-root", type=Path, required=True)
    review_parser.add_argument("--sample-id", required=True)
    review_parser.add_argument(
        "--status", choices=("provisional", "verified"), required=True
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.dataset_root.expanduser().resolve()
    try:
        if args.command == "init":
            initialize(root, args.name)
            verify_plan(root)
            print(f"PASS: 120-sample capture plan created at {plan_path(root)}")
        elif args.command == "capture":
            capture_split(
                root,
                split=args.split,
                stream_url=args.stream_url,
                allow_active_services=args.allow_active_services,
            )
        elif args.command == "verify-plan":
            verify_plan(root)
            print("PASS: capture plan has 60 validation and 60 test samples")
        elif args.command == "review":
            sample = review_sample(root, args.sample_id, status=args.status)
            print(f"PASS: reviewed {sample['sampleId']} status={args.status}")
    except (json.JSONDecodeError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
