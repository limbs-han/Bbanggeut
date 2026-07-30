#!/usr/bin/env python3
"""Create and validate a local text-plus-voice wake-name profile."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
from typing import Any, Iterable

from audio_event_detection import normalize_wake_phrase


PROFILE_FILENAME = "profile.json"
PROFILE_SCHEMA_VERSION = "1.0"
SUPPORTED_SAMPLE_SUFFIXES = frozenset(
    {".aac", ".flac", ".m4a", ".mp3", ".ogg", ".wav"}
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as input_file:
        for chunk in iter(lambda: input_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _instant() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def _validate_sample_sources(sample_paths: Iterable[Path]) -> tuple[Path, ...]:
    resolved: list[Path] = []
    for sample_path in sample_paths:
        path = sample_path.expanduser().resolve()
        if not path.is_file():
            raise ValueError(f"voice sample does not exist: {path}")
        if path.suffix.casefold() not in SUPPORTED_SAMPLE_SUFFIXES:
            raise ValueError(
                f"unsupported voice sample format: {path.suffix or '<none>'}"
            )
        if path.stat().st_size <= 0:
            raise ValueError(f"voice sample is empty: {path}")
        resolved.append(path)
    if not resolved:
        raise ValueError("at least one voice sample is required")
    return tuple(resolved)


def register_profile(
    *,
    profile_dir: Path,
    phrase: str,
    locale: str,
    sample_paths: Iterable[Path],
) -> Path:
    """Create a private local profile without replacing an existing profile."""

    normalized_phrase = normalize_wake_phrase(phrase)
    if len(normalized_phrase) < 2:
        raise ValueError("wake phrase must contain at least two letters or numbers")
    if not locale.strip():
        raise ValueError("locale cannot be empty")

    destination = profile_dir.expanduser().resolve()
    if destination.exists():
        raise FileExistsError(f"profile directory already exists: {destination}")
    sources = _validate_sample_sources(sample_paths)
    destination.parent.mkdir(parents=True, exist_ok=True)

    temporary_root = Path(
        tempfile.mkdtemp(
            prefix=f".{destination.name}.",
            dir=destination.parent,
        )
    )
    try:
        samples_dir = temporary_root / "samples"
        samples_dir.mkdir(mode=0o700)
        samples: list[dict[str, Any]] = []
        for index, source in enumerate(sources, 1):
            filename = f"sample-{index:02d}{source.suffix.casefold()}"
            target = samples_dir / filename
            shutil.copy2(source, target)
            target.chmod(0o600)
            samples.append(
                {
                    "path": f"samples/{filename}",
                    "sha256": sha256(target),
                    "sizeBytes": target.stat().st_size,
                }
            )

        payload = {
            "schemaVersion": PROFILE_SCHEMA_VERSION,
            "wakePhrase": phrase.strip(),
            "normalizedWakePhrase": normalized_phrase,
            "locale": locale.strip(),
            "recognitionMode": "speaker-independent-local-asr",
            "voiceSamplesPurpose": (
                "pronunciation-review-and-evaluation-only"
            ),
            "createdAt": _instant(),
            "samples": samples,
        }
        profile_path = temporary_root / PROFILE_FILENAME
        profile_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        profile_path.chmod(0o600)
        temporary_root.chmod(0o700)
        temporary_root.replace(destination)
    except BaseException:
        shutil.rmtree(temporary_root, ignore_errors=True)
        raise

    return destination / PROFILE_FILENAME


def load_and_validate_profile(profile_dir: Path) -> dict[str, Any]:
    root = profile_dir.expanduser().resolve()
    profile_path = root / PROFILE_FILENAME
    payload = json.loads(profile_path.read_text(encoding="utf-8"))

    if payload.get("schemaVersion") != PROFILE_SCHEMA_VERSION:
        raise ValueError("unsupported wake-name profile schema")
    phrase = str(payload.get("wakePhrase", ""))
    normalized_phrase = normalize_wake_phrase(phrase)
    if payload.get("normalizedWakePhrase") != normalized_phrase:
        raise ValueError("normalized wake phrase does not match wakePhrase")
    if len(normalized_phrase) < 2:
        raise ValueError("wake phrase must contain at least two letters or numbers")
    if payload.get("recognitionMode") != "speaker-independent-local-asr":
        raise ValueError("unsupported recognition mode")

    samples = payload.get("samples")
    if not isinstance(samples, list) or not samples:
        raise ValueError("profile must contain at least one voice sample")
    for sample in samples:
        relative_path = Path(str(sample["path"]))
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise ValueError("voice sample path must remain inside profile")
        sample_path = (root / relative_path).resolve()
        if root not in sample_path.parents:
            raise ValueError("voice sample path escapes profile")
        if not sample_path.is_file():
            raise ValueError(f"voice sample is missing: {relative_path}")
        if sample_path.stat().st_size != int(sample["sizeBytes"]):
            raise ValueError(f"voice sample size mismatch: {relative_path}")
        if sha256(sample_path) != str(sample["sha256"]):
            raise ValueError(f"voice sample checksum mismatch: {relative_path}")
    return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    register = subparsers.add_parser("register")
    register.add_argument("--profile-dir", type=Path, required=True)
    register.add_argument("--phrase", required=True)
    register.add_argument("--locale", default="ko-KR")
    register.add_argument(
        "--sample",
        type=Path,
        action="append",
        required=True,
        help="Voice sample file. Repeat for additional samples.",
    )

    validate = subparsers.add_parser("validate")
    validate.add_argument("--profile-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "register":
        profile_path = register_profile(
            profile_dir=args.profile_dir,
            phrase=args.phrase,
            locale=args.locale,
            sample_paths=args.sample,
        )
        print(f"Created local wake-name profile: {profile_path}")
        return

    payload = load_and_validate_profile(args.profile_dir)
    print(
        "PASS: valid speaker-independent wake-name profile "
        f"phrase={payload['wakePhrase']} samples={len(payload['samples'])}"
    )


if __name__ == "__main__":
    main()
