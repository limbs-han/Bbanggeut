#!/usr/bin/env python3
"""Bound Jetson event artifacts by age, directory size, and disk free space."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
import shutil
import sys
import time


MARKER = ".william-james-events"
ARTIFACT_SUFFIXES = (
    ".upload-blocked.json.tmp",
    ".upload-status.json.tmp",
    ".trigger.json.tmp",
    ".uploaded.json.tmp",
    ".merged.json.tmp",
    ".upload-blocked.json",
    ".upload-status.json",
    ".trigger.json",
    ".uploaded.json",
    ".merged.json",
    ".video.mp4",
    ".audio.wav",
    ".tmp.mp4",
    ".mp4",
)


@dataclass(frozen=True)
class Candidate:
    priority: int
    modified_at: float
    label: str
    paths: tuple[Path, ...]


def positive_number(name: str, default: str) -> float:
    raw = os.getenv(name, default)
    try:
        value = float(raw)
    except ValueError as error:
        raise ValueError(f"{name} must be a positive number") from error
    if value <= 0:
        raise ValueError(f"{name} must be a positive number")
    return value


def safe_event_dir(raw: str) -> Path:
    path = Path(raw).expanduser()
    if not path.is_absolute():
        raise ValueError("EVENT_DIR must be absolute")
    path = path.resolve()
    unsafe = {
        Path(item)
        for item in (
            "/", "/bin", "/boot", "/dev", "/etc", "/home", "/opt",
            "/root", "/run", "/srv", "/tmp", "/usr", "/var", "/var/lib",
        )
    }
    if path in unsafe:
        raise ValueError(f"Refusing unsafe EVENT_DIR: {path}")
    if not (path / MARKER).is_file():
        raise ValueError(f"Event safety marker is missing: {path / MARKER}")
    return path


def artifact_event_id(name: str) -> str | None:
    for suffix in ARTIFACT_SUFFIXES:
        if name.endswith(suffix) and len(name) > len(suffix):
            return name[: -len(suffix)]
    return None


def tree_bytes(root: Path) -> int:
    total = 0
    for directory, _, filenames in os.walk(root, followlinks=False):
        base = Path(directory)
        for filename in filenames:
            path = base / filename
            try:
                if not path.is_symlink():
                    total += path.stat().st_size
            except FileNotFoundError:
                pass
    return total


def tree_modified_at(path: Path) -> float:
    latest = path.stat().st_mtime
    if not path.is_dir():
        return latest
    for directory, directory_names, filenames in os.walk(path, followlinks=False):
        base = Path(directory)
        directory_names[:] = [
            name for name in directory_names if not (base / name).is_symlink()
        ]
        for name in (*directory_names, *filenames):
            child = base / name
            try:
                if not child.is_symlink():
                    latest = max(latest, child.stat().st_mtime)
            except FileNotFoundError:
                pass
    return latest


def candidates(event_dir: Path) -> tuple[list[Candidate], list[Path]]:
    groups: dict[str, list[Path]] = {}
    unknown: list[Path] = []
    for path in event_dir.iterdir():
        if path.name == MARKER:
            continue
        if path.is_symlink():
            unknown.append(path)
            continue
        if path.is_file():
            event_id = artifact_event_id(path.name)
            if event_id is None:
                unknown.append(path)
            else:
                groups.setdefault(event_id, []).append(path)

    result: list[Candidate] = []
    for event_id, paths in groups.items():
        names = {path.name for path in paths}
        if any(
            name.startswith(f"{event_id}.upload-blocked.json")
            for name in names
        ):
            priority = 0
        elif any(
            name.startswith(f"{event_id}.uploaded.json")
            or name.startswith(f"{event_id}.merged.json")
            for name in names
        ):
            priority = 1
        else:
            priority = 3
        result.append(
            Candidate(
                priority=priority,
                modified_at=max(path.stat().st_mtime for path in paths),
                label=f"event {event_id}",
                paths=tuple(sorted(paths)),
            )
        )

    for parent_name in ("logs", "diagnostics"):
        parent = event_dir / parent_name
        if not parent.is_dir() or parent.is_symlink():
            continue
        for path in parent.iterdir():
            if path.is_symlink():
                unknown.append(path)
                continue
            result.append(
                Candidate(
                    priority=2,
                    modified_at=tree_modified_at(path),
                    label=f"{parent_name} {path.name}",
                    paths=(path,),
                )
            )
    return result, unknown


def remove_candidate(event_dir: Path, candidate: Candidate, reason: str) -> None:
    for path in candidate.paths:
        try:
            path.relative_to(event_dir)
        except ValueError as error:
            raise RuntimeError(f"Refusing path outside EVENT_DIR: {path}") from error
        if path.is_symlink():
            raise RuntimeError(f"Refusing symlink event artifact: {path}")
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)
    print(f"Pruned {candidate.label}: {reason}")


def prune(now: float | None = None) -> int:
    current_time = time.time() if now is None else now
    event_dir = safe_event_dir(os.getenv("EVENT_DIR", "/home/ssafy/ai_events"))
    retention = positive_number("EVENT_RETENTION_DAYS", "7") * 86400
    blocked_retention = positive_number("EVENT_BLOCKED_RETENTION_DAYS", "3") * 86400
    recording_retention = positive_number("RECORDING_RETENTION_DAYS", "7") * 86400
    if blocked_retention > recording_retention:
        raise ValueError(
            "EVENT_BLOCKED_RETENTION_DAYS must not exceed "
            "RECORDING_RETENTION_DAYS"
        )
    log_retention = positive_number("EVENT_LOG_RETENTION_DAYS", "3") * 86400
    active_grace = positive_number("EVENT_ACTIVE_GRACE_MINUTES", "15") * 60
    maximum_bytes = int(positive_number("EVENT_MAX_GIB", "2") * 1024**3)
    minimum_free_bytes = int(positive_number("EVENT_MIN_FREE_GIB", "4") * 1024**3)

    items, unknown = candidates(event_dir)
    for item in sorted(items, key=lambda value: value.modified_at):
        age = current_time - item.modified_at
        limit = (
            blocked_retention if item.priority == 0
            else log_retention if item.priority == 2
            else retention
        )
        if age > limit and age > active_grace:
            remove_candidate(event_dir, item, "retention expired")

    items, unknown = candidates(event_dir)
    while True:
        used = tree_bytes(event_dir)
        free = shutil.disk_usage(event_dir).free
        if used <= maximum_bytes and free >= minimum_free_bytes:
            break
        eligible = [
            item for item in items
            if current_time - item.modified_at > active_grace
            and all(path.exists() for path in item.paths)
        ]
        if not eligible:
            print(
                "Event storage limits remain exceeded, but no inactive known "
                "artifact can be pruned",
                file=sys.stderr,
            )
            return 1
        victim = min(eligible, key=lambda item: (item.priority, item.modified_at))
        reason = (
            f"storage pressure (used={used}, max={maximum_bytes}, "
            f"free={free}, minimum_free={minimum_free_bytes})"
        )
        remove_candidate(event_dir, victim, reason)
        items.remove(victim)

    used = tree_bytes(event_dir)
    free = shutil.disk_usage(event_dir).free
    print(
        f"Event usage: {used} bytes / {maximum_bytes} bytes; "
        f"filesystem free: {free} bytes / required {minimum_free_bytes} bytes"
    )
    if unknown:
        print(
            "Ignored unknown or symlink artifacts: "
            + ", ".join(str(path) for path in sorted(unknown)),
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(prune())
    except (OSError, RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1) from error
