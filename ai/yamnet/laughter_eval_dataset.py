#!/usr/bin/env python3
"""Create, finalize, validate, and catalog laughter evaluation samples."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Any, Callable, Iterable


SCHEMA_VERSION = "1.0"
SAMPLE_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
STANDARD_ARTIFACTS = (
    "source_segment.ts",
    "context.mp4",
    "audio_16k_mono.wav",
    "waveform.png",
    "yamnet_diagnostics.jsonl",
    "operator_window.txt",
)
Runner = Callable[..., Any]


def instant(value: datetime) -> str:
    return (
        value.astimezone(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def parse_instant(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must include a timezone")
    return parsed.astimezone(timezone.utc)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write_text(path: Path, text: str) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    temporary.replace(path)


def validate_sample_id(sample_id: str) -> None:
    if not SAMPLE_ID_PATTERN.fullmatch(sample_id):
        raise ValueError(
            "sampleId must contain only letters, digits, '.', '_', or '-'"
        )


def validate_annotation_bounds(
    start_seconds: float,
    end_seconds: float,
    duration_seconds: float,
) -> None:
    if start_seconds < 0:
        raise ValueError("annotation start must be zero or greater")
    if end_seconds <= start_seconds:
        raise ValueError("annotation end must be greater than its start")
    if duration_seconds <= 0:
        raise ValueError("sample duration must be positive")
    if end_seconds > duration_seconds + 0.001:
        raise ValueError("annotation end exceeds the sample duration")


def file_manifest(root: Path, names: Iterable[str]) -> dict[str, dict[str, Any]]:
    manifest: dict[str, dict[str, Any]] = {}
    for name in sorted(set(names)):
        relative = Path(name)
        if relative.is_absolute() or len(relative.parts) != 1:
            raise ValueError(f"artifact must be a plain filename: {name}")
        path = root / relative
        if not path.is_file():
            raise ValueError(f"sample artifact is missing: {path}")
        manifest[name] = {
            "sha256": sha256(path),
            "sizeBytes": path.stat().st_size,
        }
    return manifest


def sample_artifact_names(root: Path, payload: dict[str, Any]) -> list[str]:
    names = set(payload.get("files", {}).keys())
    names.update(name for name in STANDARD_ARTIFACTS if (root / name).is_file())
    return sorted(names)


def load_metadata(sample_dir: Path) -> dict[str, Any]:
    path = sample_dir / "metadata.json"
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"metadata must be a JSON object: {path}")
    return payload


def validate_sample(sample_dir: Path) -> dict[str, Any]:
    payload = load_metadata(sample_dir)
    if payload.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError(f"unsupported sample schema: {payload.get('schemaVersion')}")

    sample_id = str(payload.get("sampleId", ""))
    validate_sample_id(sample_id)

    source = payload.get("source")
    ground_truth = payload.get("groundTruth")
    environment = payload.get("environment")
    result = payload.get("result")
    files = payload.get("files")
    if not all(
        isinstance(value, dict)
        for value in (source, ground_truth, environment, result, files)
    ):
        raise ValueError(f"sample metadata is missing required objects: {sample_dir}")

    duration = float(source["requestedDurationSeconds"])
    start = float(ground_truth["startSeconds"])
    end = float(ground_truth["endSeconds"])
    validate_annotation_bounds(start, end, duration)

    status = str(ground_truth.get("annotationStatus", ""))
    if status not in {"provisional", "verified"}:
        raise ValueError(f"unsupported annotationStatus: {status}")
    if status == "verified" and ground_truth.get("manualReviewRequired") is not False:
        raise ValueError("verified annotations must set manualReviewRequired=false")

    for filename, expected in files.items():
        if Path(filename).is_absolute() or len(Path(filename).parts) != 1:
            raise ValueError(f"artifact must be a plain filename: {filename}")
        path = sample_dir / filename
        if not path.is_file():
            raise ValueError(f"sample artifact is missing: {path}")
        if path.stat().st_size != int(expected["sizeBytes"]):
            raise ValueError(f"artifact size mismatch: {path}")
        if sha256(path) != str(expected["sha256"]):
            raise ValueError(f"artifact checksum mismatch: {path}")

    return payload


def build_audio_command(
    ffmpeg: str,
    source: Path,
    destination: Path,
    offset_seconds: float,
    duration_seconds: float,
) -> list[str]:
    return [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(source),
        "-ss",
        f"{offset_seconds:.6f}",
        "-t",
        f"{duration_seconds:.6f}",
        "-map",
        "0:a:0",
        "-ac",
        "1",
        "-ar",
        "16000",
        "-c:a",
        "pcm_s16le",
        str(destination),
    ]


def build_context_command(
    ffmpeg: str,
    source: Path,
    destination: Path,
    offset_seconds: float,
    duration_seconds: float,
) -> list[str]:
    return [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        f"{offset_seconds:.6f}",
        "-i",
        str(source),
        "-t",
        f"{duration_seconds:.6f}",
        "-map",
        "0:v:0",
        "-map",
        "0:a:0",
        "-c",
        "copy",
        "-avoid_negative_ts",
        "make_zero",
        str(destination),
    ]


def build_waveform_command(
    ffmpeg: str,
    source: Path,
    destination: Path,
) -> list[str]:
    return [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(source),
        "-filter_complex",
        "showwavespic=s=1600x400:colors=0x37B7C3",
        "-frames:v",
        "1",
        str(destination),
    ]


def run_checked(runner: Runner, command: list[str]) -> None:
    runner(command, check=True)


def optional_result_metrics(args: argparse.Namespace) -> dict[str, Any]:
    result: dict[str, Any] = {"classification": args.result}
    values = (
        ("maximumSelectedScore", args.maximum_selected_score),
        ("maximumPositiveStreak", args.maximum_positive_streak),
        ("maximumRms", args.maximum_rms),
    )
    result.update({key: value for key, value in values if value is not None})
    if args.observed_top_class:
        result["observedTopClasses"] = list(dict.fromkeys(args.observed_top_class))
    return result


def create_sample(args: argparse.Namespace, runner: Runner = subprocess.run) -> Path:
    source = Path(args.source_segment).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    if not source.is_file():
        raise ValueError(f"source segment does not exist: {source}")
    if output_dir.exists():
        raise ValueError(f"output directory already exists: {output_dir}")
    validate_sample_id(args.sample_id)
    if args.context_offset_seconds < 0:
        raise ValueError("context offset must be zero or greater")
    validate_annotation_bounds(
        args.label_start_seconds,
        args.label_end_seconds,
        args.context_duration_seconds,
    )
    segment_started_at = parse_instant(args.segment_started_at)
    context_started_at = segment_started_at + timedelta(
        seconds=args.context_offset_seconds
    )

    output_dir.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=f".{output_dir.name}.",
        dir=output_dir.parent,
    ) as temporary_name:
        temporary = Path(temporary_name)
        source_copy = temporary / "source_segment.ts"
        audio = temporary / "audio_16k_mono.wav"
        context = temporary / "context.mp4"
        waveform = temporary / "waveform.png"
        shutil.copy2(source, source_copy)

        run_checked(
            runner,
            build_audio_command(
                args.ffmpeg,
                source_copy,
                audio,
                args.context_offset_seconds,
                args.context_duration_seconds,
            ),
        )
        run_checked(
            runner,
            build_context_command(
                args.ffmpeg,
                source_copy,
                context,
                args.context_offset_seconds,
                args.context_duration_seconds,
            ),
        )
        run_checked(
            runner,
            build_waveform_command(args.ffmpeg, audio, waveform),
        )

        evidence_names: list[str] = []
        for source_name, destination_name in (
            (args.diagnostics_jsonl, "yamnet_diagnostics.jsonl"),
            (args.operator_window, "operator_window.txt"),
        ):
            if source_name:
                evidence_source = Path(source_name).expanduser().resolve()
                if not evidence_source.is_file():
                    raise ValueError(f"evidence file does not exist: {evidence_source}")
                shutil.copy2(evidence_source, temporary / destination_name)
                evidence_names.append(destination_name)

        artifact_names = [
            "source_segment.ts",
            "audio_16k_mono.wav",
            "context.mp4",
            "waveform.png",
            *evidence_names,
        ]
        payload = {
            "schemaVersion": SCHEMA_VERSION,
            "sampleId": args.sample_id,
            "environment": {
                "name": args.environment,
                "captureDevice": args.capture_device,
                "targetDevice": args.target_device,
                "targetDeviceValidation": args.target_device_validation,
            },
            "source": {
                "segmentStartedAt": instant(segment_started_at),
                "requestedContextStartedAt": instant(context_started_at),
                "requestedDurationSeconds": args.context_duration_seconds,
            },
            "groundTruth": {
                "label": args.label,
                "annotationStatus": args.annotation_status,
                "timelineReference": "audio_16k_mono.wav",
                "startSeconds": args.label_start_seconds,
                "endSeconds": args.label_end_seconds,
                "source": args.annotation_source,
                "manualReviewRequired": args.annotation_status != "verified",
            },
            "detector": {
                "model": "YAMNet",
                "scoreAggregation": args.score_aggregation,
                "threshold": args.threshold,
                "consecutive": args.consecutive,
                "gain": args.gain,
            },
            "result": optional_result_metrics(args),
            "files": file_manifest(temporary, artifact_names),
            "notes": list(args.note or []),
        }
        atomic_write_text(
            temporary / "metadata.json",
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        )
        temporary.replace(output_dir)

    validate_sample(output_dir)
    return output_dir


def finalize_sample(
    sample_dir: Path,
    *,
    start_seconds: float,
    end_seconds: float,
    audio_clarity: str,
    reviewed_at: str | None = None,
) -> dict[str, Any]:
    sample_dir = sample_dir.expanduser().resolve()
    payload = load_metadata(sample_dir)
    duration = float(payload["source"]["requestedDurationSeconds"])
    validate_annotation_bounds(start_seconds, end_seconds, duration)
    reviewed = parse_instant(reviewed_at) if reviewed_at else datetime.now(timezone.utc)

    payload["groundTruth"].update(
        {
            "annotationStatus": "verified",
            "startSeconds": start_seconds,
            "endSeconds": end_seconds,
            "source": "manual_playback",
            "manualReviewRequired": False,
        }
    )
    payload["review"] = {
        "reviewedAt": instant(reviewed),
        "method": "manual_playback",
        "audioClarity": audio_clarity,
    }
    names = sample_artifact_names(sample_dir, payload)
    payload["files"] = file_manifest(sample_dir, names)
    atomic_write_text(
        sample_dir / "metadata.json",
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
    )
    return validate_sample(sample_dir)


def catalog_entry(
    dataset_root: Path,
    sample_dir: Path,
    payload: dict[str, Any],
) -> dict[str, Any]:
    return {
        "sampleId": payload["sampleId"],
        "sampleDirectory": sample_dir.relative_to(dataset_root).as_posix(),
        "environment": payload["environment"].get(
            "name",
            payload["environment"].get("location"),
        ),
        "captureDevice": payload["environment"].get("captureDevice"),
        "targetDeviceValidation": bool(
            payload["environment"].get("targetDeviceValidation")
        ),
        "label": payload["groundTruth"]["label"],
        "annotationStatus": payload["groundTruth"]["annotationStatus"],
        "startSeconds": payload["groundTruth"]["startSeconds"],
        "endSeconds": payload["groundTruth"]["endSeconds"],
        "classification": payload["result"]["classification"],
        "maximumSelectedScore": payload["result"].get("maximumSelectedScore"),
    }


def catalog_dataset(
    dataset_root: Path,
    output_dir: Path | None = None,
    *,
    generated_at: datetime | None = None,
) -> list[dict[str, Any]]:
    dataset_root = dataset_root.expanduser().resolve()
    if not dataset_root.is_dir():
        raise ValueError(f"dataset root does not exist: {dataset_root}")
    output_dir = (
        output_dir.expanduser().resolve() if output_dir is not None else dataset_root
    )

    entries: list[dict[str, Any]] = []
    sample_ids: set[str] = set()
    for metadata_path in sorted(dataset_root.rglob("metadata.json")):
        sample_dir = metadata_path.parent
        payload = validate_sample(sample_dir)
        sample_id = str(payload["sampleId"])
        if sample_id in sample_ids:
            raise ValueError(f"duplicate sampleId: {sample_id}")
        sample_ids.add(sample_id)
        entries.append(catalog_entry(dataset_root, sample_dir, payload))
    if not entries:
        raise ValueError(f"no metadata.json files found under {dataset_root}")
    entries.sort(key=lambda entry: str(entry["sampleId"]))

    output_dir.mkdir(parents=True, exist_ok=True)
    generated = instant(generated_at or datetime.now(timezone.utc))
    atomic_write_text(
        output_dir / "catalog.json",
        json.dumps(
            {
                "schemaVersion": SCHEMA_VERSION,
                "generatedAt": generated,
                "sampleCount": len(entries),
                "samples": entries,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
    )

    csv_output = io.StringIO(newline="")
    fieldnames = list(entries[0].keys())
    writer = csv.DictWriter(csv_output, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(entries)
    atomic_write_text(output_dir / "catalog.csv", csv_output.getvalue())

    markdown = [
        "# Laughter evaluation dataset catalog",
        "",
        f"- Generated at: `{generated}`",
        f"- Samples: `{len(entries)}`",
        "",
        "| Sample | Environment | Device | Label | Annotation | Result |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for entry in entries:
        markdown.append(
            "| {sampleId} | {environment} | {captureDevice} | {label} | "
            "{annotationStatus} | {classification} |".format(**entry)
        )
    atomic_write_text(output_dir / "catalog.md", "\n".join(markdown) + "\n")
    return entries


def add_create_parser(subparsers: Any) -> None:
    parser = subparsers.add_parser("create", help="Create one evaluation sample")
    parser.add_argument("--source-segment", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--sample-id", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--capture-device", required=True)
    parser.add_argument("--target-device", default="Logitech BRIO 100")
    parser.add_argument("--target-device-validation", action="store_true")
    parser.add_argument("--segment-started-at", required=True)
    parser.add_argument("--context-offset-seconds", type=float, required=True)
    parser.add_argument("--context-duration-seconds", type=float, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--label-start-seconds", type=float, required=True)
    parser.add_argument("--label-end-seconds", type=float, required=True)
    parser.add_argument(
        "--annotation-status",
        choices=("provisional", "verified"),
        default="provisional",
    )
    parser.add_argument(
        "--annotation-source",
        default="operator_prompt_window",
    )
    parser.add_argument(
        "--result",
        choices=(
            "true_positive",
            "false_negative",
            "false_positive",
            "true_negative",
            "unverified",
        ),
        default="unverified",
    )
    parser.add_argument("--score-aggregation", choices=("max", "mean", "p90"))
    parser.add_argument("--threshold", type=float)
    parser.add_argument("--consecutive", type=int)
    parser.add_argument("--gain", type=float)
    parser.add_argument("--maximum-selected-score", type=float)
    parser.add_argument("--maximum-positive-streak", type=int)
    parser.add_argument("--maximum-rms", type=float)
    parser.add_argument("--observed-top-class", action="append")
    parser.add_argument("--diagnostics-jsonl")
    parser.add_argument("--operator-window")
    parser.add_argument("--note", action="append")
    parser.add_argument(
        "--ffmpeg",
        default=os.getenv("FFMPEG_PATH", "/usr/bin/ffmpeg"),
    )
    parser.set_defaults(command_handler=lambda args: print(create_sample(args)))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    add_create_parser(subparsers)

    finalize_parser = subparsers.add_parser(
        "finalize",
        help="Replace provisional boundaries after manual playback",
    )
    finalize_parser.add_argument("--sample-dir", required=True)
    finalize_parser.add_argument("--start-seconds", required=True, type=float)
    finalize_parser.add_argument("--end-seconds", required=True, type=float)
    finalize_parser.add_argument(
        "--audio-clarity",
        required=True,
        choices=("clear", "unclear", "unusable"),
    )
    finalize_parser.add_argument("--reviewed-at")

    validate_parser = subparsers.add_parser(
        "validate",
        help="Verify one sample's schema, sizes, and SHA-256 values",
    )
    validate_parser.add_argument("--sample-dir", required=True)

    catalog_parser = subparsers.add_parser(
        "catalog",
        help="Validate every sample and write JSON, CSV, and Markdown catalogs",
    )
    catalog_parser.add_argument("--dataset-root", required=True)
    catalog_parser.add_argument("--output-dir")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.command == "create":
            args.command_handler(args)
        elif args.command == "finalize":
            payload = finalize_sample(
                Path(args.sample_dir),
                start_seconds=args.start_seconds,
                end_seconds=args.end_seconds,
                audio_clarity=args.audio_clarity,
                reviewed_at=args.reviewed_at,
            )
            print(f"Finalized sample: {payload['sampleId']}")
        elif args.command == "validate":
            payload = validate_sample(Path(args.sample_dir).expanduser().resolve())
            print(f"PASS: valid sample {payload['sampleId']}")
        elif args.command == "catalog":
            entries = catalog_dataset(
                Path(args.dataset_root),
                Path(args.output_dir) if args.output_dir else None,
            )
            print(f"PASS: cataloged {len(entries)} samples")
    except (
        json.JSONDecodeError,
        OSError,
        subprocess.CalledProcessError,
        ValueError,
    ) as error:
        raise SystemExit(f"ERROR: {error}") from error


if __name__ == "__main__":
    main()
