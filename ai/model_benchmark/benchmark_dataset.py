#!/usr/bin/env python3
"""Create and validate reproducible local benchmark dataset manifests."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
from typing import Any


SCHEMA_VERSION = "0.1"
SAMPLE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{2,95}$")
ALLOWED_SPLITS = {"train", "validation", "test"}
ALLOWED_CONDITIONS = {
    "ambient-noise",
    "baby-laughter",
    "conversation",
    "daily-noise",
    "empty",
    "external-generalization",
    "single-person",
    "two-people",
    "movement",
    "occlusion",
    "low-light",
    "laughter",
    "laughter-with-clap",
    "music",
    "multiple-laughter",
    "quiet-office",
    "single-impact",
    "small-laughter",
    "speech",
    "consecutive-clap",
    "television-laughter",
    "tv-playback",
}


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dataset_path(root: Path) -> Path:
    return root / "dataset.json"


def load_dataset(root: Path) -> dict[str, Any]:
    path = dataset_path(root)
    if not path.is_file():
        raise ValueError(f"dataset manifest does not exist: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid dataset JSON: {error}") from error
    if not isinstance(payload, dict):
        raise ValueError("dataset manifest must be a JSON object")
    return payload


def write_dataset(root: Path, payload: dict[str, Any]) -> None:
    root.mkdir(parents=True, exist_ok=True)
    temporary = dataset_path(root).with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(dataset_path(root))


def create_dataset(root: Path, name: str) -> dict[str, Any]:
    if dataset_path(root).exists():
        raise ValueError(f"dataset already exists: {dataset_path(root)}")
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "name": name,
        "createdAt": utc_now(),
        "updatedAt": utc_now(),
        "privacy": {
            "scope": "jetson-local",
            "containsPersonalData": True,
            "gitCommitAllowed": False,
        },
        "samples": [],
    }
    write_dataset(root, payload)
    return payload


def add_sample(
    root: Path,
    sample_id: str,
    media_path: Path,
    split: str,
    conditions: list[str],
    labels: list[str],
    notes: str | None,
    duration_seconds: float | None = None,
    session_id: str | None = None,
    source_dataset: str | None = None,
    source_license: str | None = None,
) -> dict[str, Any]:
    if not SAMPLE_ID_PATTERN.fullmatch(sample_id):
        raise ValueError(
            "sample ID must use 3-96 lowercase letters, digits, dot, dash or underscore"
        )
    if split not in ALLOWED_SPLITS:
        raise ValueError(f"unsupported split: {split}")
    unsupported = sorted(set(conditions) - ALLOWED_CONDITIONS)
    if unsupported:
        raise ValueError(f"unsupported conditions: {', '.join(unsupported)}")
    if duration_seconds is not None and duration_seconds <= 0:
        raise ValueError("duration seconds must be positive")
    if session_id is not None and not SAMPLE_ID_PATTERN.fullmatch(session_id):
        raise ValueError(
            "session ID must use lowercase letters, numbers, dots, underscores or hyphens"
        )
    if bool(source_dataset) != bool(source_license):
        raise ValueError("source dataset and source license must be provided together")

    root = root.resolve()
    media_path = media_path.resolve()
    try:
        relative_media = media_path.relative_to(root)
    except ValueError as error:
        raise ValueError("media file must be stored inside the dataset root") from error
    if not media_path.is_file():
        raise ValueError(f"media file does not exist: {media_path}")

    payload = load_dataset(root)
    samples = payload.setdefault("samples", [])
    if not isinstance(samples, list):
        raise ValueError("samples must be an array")
    if any(row.get("sampleId") == sample_id for row in samples if isinstance(row, dict)):
        raise ValueError(f"duplicate sample ID: {sample_id}")

    sample = {
        "sampleId": sample_id,
        "media": relative_media.as_posix(),
        "sha256": sha256(media_path),
        "sizeBytes": media_path.stat().st_size,
        "split": split,
        "conditions": sorted(set(conditions)),
        "labels": sorted(set(labels)),
        "review": {
            "status": "provisional",
            "manualReviewRequired": True,
        },
    }
    if notes:
        sample["notes"] = notes
    if duration_seconds is not None:
        sample["durationSeconds"] = duration_seconds
    if session_id is not None:
        sample["sessionId"] = session_id
    if source_dataset and source_license:
        sample["source"] = {
            "dataset": source_dataset,
            "license": source_license,
        }

    samples.append(sample)
    payload["updatedAt"] = utc_now()
    write_dataset(root, payload)
    return sample


def review_sample(
    root: Path,
    sample_id: str,
    *,
    status: str,
    duration_seconds: float | None = None,
) -> dict[str, Any]:
    """Record a listening review without changing the media fingerprint."""

    if status not in {"provisional", "verified"}:
        raise ValueError(f"unsupported review status: {status}")
    if duration_seconds is not None and duration_seconds <= 0:
        raise ValueError("duration seconds must be positive")
    payload = load_dataset(root)
    samples = payload.get("samples")
    if not isinstance(samples, list):
        raise ValueError("samples must be an array")
    sample = next(
        (
            row
            for row in samples
            if isinstance(row, dict) and row.get("sampleId") == sample_id
        ),
        None,
    )
    if sample is None:
        raise ValueError(f"unknown sample ID: {sample_id}")
    sample["review"] = {
        "status": status,
        "manualReviewRequired": status != "verified",
        "reviewedAt": utc_now(),
    }
    if duration_seconds is not None:
        sample["durationSeconds"] = duration_seconds
    payload["updatedAt"] = utc_now()
    write_dataset(root, payload)
    return sample


def validate_dataset(root: Path) -> list[str]:
    payload = load_dataset(root)
    errors: list[str] = []

    if payload.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(f"unsupported schemaVersion: {payload.get('schemaVersion')!r}")
    samples = payload.get("samples")
    if not isinstance(samples, list):
        return errors + ["samples must be an array"]

    seen: set[str] = set()
    session_splits: dict[str, set[str]] = {}
    resolved_root = root.resolve()
    for index, sample in enumerate(samples):
        prefix = f"samples[{index}]"
        if not isinstance(sample, dict):
            errors.append(f"{prefix} must be an object")
            continue

        sample_id = sample.get("sampleId")
        if not isinstance(sample_id, str) or not SAMPLE_ID_PATTERN.fullmatch(sample_id):
            errors.append(f"{prefix}.sampleId is invalid")
        elif sample_id in seen:
            errors.append(f"duplicate sampleId: {sample_id}")
        else:
            seen.add(sample_id)

        media_value = sample.get("media")
        if not isinstance(media_value, str):
            errors.append(f"{prefix}.media is missing")
            continue
        media_path = (resolved_root / media_value).resolve()
        try:
            media_path.relative_to(resolved_root)
        except ValueError:
            errors.append(f"{prefix}.media escapes the dataset root")
            continue
        if not media_path.is_file():
            errors.append(f"{prefix}.media does not exist: {media_value}")
            continue

        expected_hash = sample.get("sha256")
        if expected_hash != sha256(media_path):
            errors.append(f"{prefix}.sha256 mismatch")
        if sample.get("sizeBytes") != media_path.stat().st_size:
            errors.append(f"{prefix}.sizeBytes mismatch")

        split = sample.get("split")
        if split not in ALLOWED_SPLITS:
            errors.append(f"{prefix}.split is invalid: {split!r}")

        session_id = sample.get("sessionId")
        if session_id is not None:
            if not isinstance(session_id, str) or not SAMPLE_ID_PATTERN.fullmatch(
                session_id
            ):
                errors.append(f"{prefix}.sessionId is invalid")
            elif split in ALLOWED_SPLITS:
                session_splits.setdefault(session_id, set()).add(split)

        conditions = sample.get("conditions")
        if not isinstance(conditions, list):
            errors.append(f"{prefix}.conditions must be an array")
        else:
            unsupported = sorted(set(conditions) - ALLOWED_CONDITIONS)
            if unsupported:
                errors.append(
                    f"{prefix}.conditions unsupported: {', '.join(unsupported)}"
                )

        duration = sample.get("durationSeconds")
        if duration is not None and (
            not isinstance(duration, (int, float)) or duration <= 0
        ):
            errors.append(f"{prefix}.durationSeconds must be positive")

        review = sample.get("review")
        if not isinstance(review, dict):
            errors.append(f"{prefix}.review must be an object")
        elif review.get("status") not in {"provisional", "verified"}:
            errors.append(f"{prefix}.review.status is invalid")
        elif (
            review.get("status") == "verified"
            and review.get("manualReviewRequired") is not False
        ):
            errors.append(
                f"{prefix}.review.manualReviewRequired must be false when verified"
            )

        source = sample.get("source")
        if source is not None and (
            not isinstance(source, dict)
            or not isinstance(source.get("dataset"), str)
            or not source.get("dataset")
            or not isinstance(source.get("license"), str)
            or not source.get("license")
        ):
            errors.append(f"{prefix}.source is invalid")

    for session_id, splits in sorted(session_splits.items()):
        if len(splits) > 1:
            errors.append(
                f"sessionId {session_id} appears in multiple splits: "
                f"{', '.join(sorted(splits))}"
            )

    return errors


def print_summary(payload: dict[str, Any]) -> None:
    samples = payload.get("samples", [])
    split_counts = {
        split: sum(
            1
            for row in samples
            if isinstance(row, dict) and row.get("split") == split
        )
        for split in sorted(ALLOWED_SPLITS)
    }
    condition_counts = {
        condition: sum(
            1
            for row in samples
            if isinstance(row, dict)
            and condition in row.get("conditions", [])
        )
        for condition in sorted(ALLOWED_CONDITIONS)
    }
    summary = {
        "name": payload.get("name"),
        "sampleCount": len(samples),
        "splits": split_counts,
        "conditions": condition_counts,
        "labels": {
            label: sum(
                1
                for row in samples
                if isinstance(row, dict) and label in row.get("labels", [])
            )
            for label in sorted(
                {
                    label
                    for row in samples
                    if isinstance(row, dict)
                    for label in row.get("labels", [])
                    if isinstance(label, str)
                }
            )
        },
        "reviews": {
            status: sum(
                1
                for row in samples
                if isinstance(row, dict)
                and isinstance(row.get("review"), dict)
                and row["review"].get("status") == status
            )
            for status in ("provisional", "verified")
        },
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Manage a local-only AI benchmark dataset manifest."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init")
    init_parser.add_argument("--dataset-root", type=Path, required=True)
    init_parser.add_argument("--name", required=True)

    add_parser = subparsers.add_parser("add")
    add_parser.add_argument("--dataset-root", type=Path, required=True)
    add_parser.add_argument("--sample-id", required=True)
    add_parser.add_argument("--media", type=Path, required=True)
    add_parser.add_argument("--split", choices=sorted(ALLOWED_SPLITS), required=True)
    add_parser.add_argument(
        "--condition",
        action="append",
        dest="conditions",
        default=[],
        choices=sorted(ALLOWED_CONDITIONS),
    )
    add_parser.add_argument("--label", action="append", dest="labels", default=[])
    add_parser.add_argument("--duration-seconds", type=float)
    add_parser.add_argument("--session-id")
    add_parser.add_argument("--source-dataset")
    add_parser.add_argument("--source-license")
    add_parser.add_argument("--notes")

    review_parser = subparsers.add_parser("review")
    review_parser.add_argument("--dataset-root", type=Path, required=True)
    review_parser.add_argument("--sample-id", required=True)
    review_parser.add_argument(
        "--status",
        choices=("provisional", "verified"),
        required=True,
    )
    review_parser.add_argument("--duration-seconds", type=float)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--dataset-root", type=Path, required=True)

    summary_parser = subparsers.add_parser("summary")
    summary_parser.add_argument("--dataset-root", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.dataset_root.expanduser().resolve()
    try:
        if args.command == "init":
            create_dataset(root, args.name)
            print(f"PASS: created dataset manifest at {dataset_path(root)}")
        elif args.command == "add":
            sample = add_sample(
                root=root,
                sample_id=args.sample_id,
                media_path=args.media,
                split=args.split,
                conditions=args.conditions,
                labels=args.labels,
                notes=args.notes,
                duration_seconds=args.duration_seconds,
                session_id=args.session_id,
                source_dataset=args.source_dataset,
                source_license=args.source_license,
            )
            print(f"PASS: added sample {sample['sampleId']}")
        elif args.command == "review":
            sample = review_sample(
                root,
                args.sample_id,
                status=args.status,
                duration_seconds=args.duration_seconds,
            )
            print(
                f"PASS: reviewed {sample['sampleId']} "
                f"status={sample['review']['status']}"
            )
        elif args.command == "validate":
            errors = validate_dataset(root)
            if errors:
                for error in errors:
                    print(f"ERROR: {error}")
                return 1
            print(f"PASS: valid dataset with {len(load_dataset(root)['samples'])} samples")
        elif args.command == "summary":
            print_summary(load_dataset(root))
    except ValueError as error:
        print(f"ERROR: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
