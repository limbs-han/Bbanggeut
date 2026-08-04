#!/usr/bin/env python3
"""Download, verify, and register pinned ESC-50 v2.0.0 benchmark audio."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
from typing import Any, Sequence
from urllib.request import urlopen
import zipfile

from benchmark_dataset import create_dataset, load_dataset, sha256, utc_now, write_dataset


ESC50_COMMIT = "33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6"
ARCHIVE_NAME = f"ESC-50-{ESC50_COMMIT}.zip"
ARCHIVE_URL = (
    "https://github.com/karolpiczak/ESC-50/archive/"
    f"{ESC50_COMMIT}.zip"
)
EXPECTED_ARCHIVE_MD5 = "071b44018315e034b2c6e8064543d19c"
SOURCE_DIRECTORY = f"ESC-50-{ESC50_COMMIT}"
LICENSE_NAME = "CC BY-NC 3.0"


def digest(path: Path, algorithm: str) -> str:
    checksum = hashlib.new(algorithm)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def download_archive(destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".zip.tmp")
    with urlopen(ARCHIVE_URL, timeout=60) as response, temporary.open("wb") as output:
        shutil.copyfileobj(response, output, length=1024 * 1024)
    temporary.replace(destination)


def safe_member(member: str) -> bool:
    path = PurePosixPath(member)
    return bool(path.parts) and not path.is_absolute() and ".." not in path.parts


def extract_required(archive: Path, destination: Path) -> Path:
    source_root = destination / SOURCE_DIRECTORY
    if source_root.exists():
        return source_root
    temporary = destination / f".{SOURCE_DIRECTORY}.extracting"
    if temporary.exists():
        shutil.rmtree(temporary)
    temporary.mkdir(parents=True)
    with zipfile.ZipFile(archive) as bundle:
        archive_members = bundle.infolist()
        if any(not safe_member(info.filename) for info in archive_members):
            raise ValueError("ESC-50 archive contains an unsafe path")
        members = [
            info
            for info in archive_members
            if info.filename.startswith(f"{SOURCE_DIRECTORY}/")
            and (
                "/audio/" in info.filename
                or info.filename.endswith("/meta/esc50.csv")
                or info.filename.endswith("/LICENSE")
            )
        ]
        if not members:
            raise ValueError("ESC-50 archive is missing required paths")
        for info in members:
            relative = PurePosixPath(info.filename).relative_to(SOURCE_DIRECTORY)
            target = temporary.joinpath(*relative.parts)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(info) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output)
    temporary.replace(source_root)
    return source_root


def event_labels(category: str) -> tuple[str, ...]:
    if category == "laughing":
        return ("laughter",)
    if category == "clapping":
        return ("clap",)
    return ()


def event_conditions(category: str) -> tuple[str, ...]:
    if category == "laughing":
        return ("external-generalization", "laughter")
    if category == "clapping":
        return ("consecutive-clap", "external-generalization")
    return ("ambient-noise", "external-generalization")


def build_manifest(
    dataset_root: Path,
    source_root: Path,
    *,
    archive_sha256: str,
    require_full_dataset: bool = True,
    append: bool = False,
) -> dict[str, Any]:
    metadata_path = source_root / "meta" / "esc50.csv"
    audio_root = source_root / "audio"
    if not metadata_path.is_file() or not audio_root.is_dir():
        raise ValueError("ESC-50 metadata or audio directory is missing")
    if append:
        if not (dataset_root / "dataset.json").is_file():
            raise ValueError("--append requires an existing dataset manifest")
    else:
        create_dataset(dataset_root, "esc50-audio-events-v2.0.0")
    payload = load_dataset(dataset_root)
    if not append:
        payload["privacy"] = {
            "scope": "jetson-local",
            "containsPersonalData": False,
            "gitCommitAllowed": False,
        }
    provenance = {
        "dataset": "ESC-50",
        "version": "2.0.0",
        "sourceCommit": ESC50_COMMIT,
        "sourceUrl": ARCHIVE_URL,
        "archiveMd5": EXPECTED_ARCHIVE_MD5,
        "archiveSha256": archive_sha256,
        "license": LICENSE_NAME,
        "usage": "non-commercial evaluation only",
    }
    external_sources = payload.setdefault("externalSources", [])
    if not isinstance(external_sources, list):
        raise ValueError("dataset externalSources must be an array")
    if not any(
        isinstance(row, dict) and row.get("sourceCommit") == ESC50_COMMIT
        for row in external_sources
    ):
        external_sources.append(provenance)
    rows: list[dict[str, Any]] = []
    category_counts: dict[str, int] = {}
    with metadata_path.open("r", encoding="utf-8", newline="") as source:
        for metadata in csv.DictReader(source):
            filename = metadata.get("filename", "")
            category = metadata.get("category", "")
            media = audio_root / filename
            if not filename or not category or not media.is_file():
                raise ValueError(f"invalid ESC-50 metadata row: {metadata}")
            category_counts[category] = category_counts.get(category, 0) + 1
            relative_media = media.resolve().relative_to(dataset_root.resolve())
            rows.append(
                {
                    "sampleId": f"esc50-{Path(filename).stem.lower()}",
                    "media": relative_media.as_posix(),
                    "sha256": sha256(media),
                    "sizeBytes": media.stat().st_size,
                    "split": "test",
                    "conditions": list(event_conditions(category)),
                    "labels": list(event_labels(category)),
                    "durationSeconds": 5.0,
                    "sessionId": f"esc50-fold-{metadata.get('fold', 'unknown')}",
                    "review": {
                        "status": "verified",
                        "manualReviewRequired": False,
                        "reviewedAt": utc_now(),
                        "basis": "official ESC-50 metadata",
                    },
                    "source": {
                        "dataset": "ESC-50 v2.0.0",
                        "license": LICENSE_NAME,
                        "category": category,
                        "sourceFile": metadata.get("src_file"),
                    },
                }
            )
    if require_full_dataset:
        expected = {"laughing": 40, "clapping": 40}
        if len(rows) != 2000 or any(category_counts.get(key) != value for key, value in expected.items()):
            raise ValueError(
                "ESC-50 expected 2000 clips with 40 laughing and 40 clapping clips"
            )
    existing_rows = payload.get("samples", [])
    if not isinstance(existing_rows, list):
        raise ValueError("dataset samples must be an array")
    existing_ids = {
        row.get("sampleId") for row in existing_rows if isinstance(row, dict)
    }
    duplicate_ids = sorted(
        row["sampleId"] for row in rows if row["sampleId"] in existing_ids
    )
    if duplicate_ids:
        raise ValueError(f"ESC-50 samples already registered: {duplicate_ids[0]}")
    payload["samples"] = [*existing_rows, *rows]
    payload["updatedAt"] = utc_now()
    write_dataset(dataset_root, payload)
    return payload


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument(
        "--cache-root",
        type=Path,
        default=Path.home() / "ai_models" / "audio-benchmark" / "datasets",
    )
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--download", action="store_true")
    parser.add_argument(
        "--append",
        action="store_true",
        help="Append ESC-50 test rows to an existing direct-capture dataset.",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    dataset_root = args.dataset_root.expanduser().resolve()
    cache_root = args.cache_root.expanduser().resolve()
    archive = (
        args.archive.expanduser().resolve()
        if args.archive
        else cache_root / ARCHIVE_NAME
    )
    created_dataset_root = not dataset_root.exists()
    try:
        if dataset_root.exists() and not args.append:
            raise ValueError(f"dataset root already exists: {dataset_root}")
        if args.append and not (dataset_root / "dataset.json").is_file():
            raise ValueError("--append requires an existing dataset root")
        if not archive.is_file():
            if not args.download:
                raise ValueError(
                    f"archive is missing: {archive}; rerun with --download"
                )
            print(f"DOWNLOAD={ARCHIVE_URL}")
            download_archive(archive)
        actual_md5 = digest(archive, "md5")
        print(f"EXPECTED_MD5={EXPECTED_ARCHIVE_MD5}")
        print(f"ACTUAL_MD5={actual_md5}")
        if actual_md5 != EXPECTED_ARCHIVE_MD5:
            raise ValueError("ESC-50 archive checksum mismatch")
        dataset_root.mkdir(parents=True, exist_ok=args.append)
        source_root = extract_required(archive, dataset_root / "source")
        payload = build_manifest(
            dataset_root,
            source_root,
            archive_sha256=digest(archive, "sha256"),
            append=args.append,
        )
        esc50_rows = [
            row
            for row in payload["samples"]
            if isinstance(row.get("source"), dict)
            and row["source"].get("dataset") == "ESC-50 v2.0.0"
        ]
        print(f"TOTAL_SAMPLES={len(payload['samples'])}")
        print(f"ESC50_SAMPLES={len(esc50_rows)}")
        print(f"ESC50_LAUGHTER={sum('laughter' in row['labels'] for row in esc50_rows)}")
        print(f"ESC50_CLAP={sum('clap' in row['labels'] for row in esc50_rows)}")
        print(f"ESC50_NEGATIVE={sum(not row['labels'] for row in esc50_rows)}")
        print(f"PASS: pinned ESC-50 benchmark prepared at {dataset_root}")
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        if (
            dataset_root.exists()
            and not args.append
            and created_dataset_root
        ):
            shutil.rmtree(dataset_root)
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
