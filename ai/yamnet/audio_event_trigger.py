"""Atomic local trigger writer shared by audio event detectors."""

from __future__ import annotations

from datetime import datetime
import json
import os
from pathlib import Path
from typing import Any


AUDIO_EVENT_TYPES = frozenset({"LAUGHTER", "CLAP", "WAKE_WORD"})


def build_audio_event_payload(
    *,
    event_id: str,
    event_type: str,
    occurred_at: datetime,
    confidence: float,
    class_name: str,
    clip_seconds: float,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    normalized_type = event_type.strip().upper()
    if normalized_type not in AUDIO_EVENT_TYPES:
        raise ValueError(
            f"event_type must be one of {sorted(AUDIO_EVENT_TYPES)}"
        )
    if not event_id.strip():
        raise ValueError("event_id cannot be empty")
    if occurred_at.tzinfo is None:
        raise ValueError("occurred_at must include a timezone")
    if not 0.0 <= confidence <= 1.0:
        raise ValueError("confidence must be between 0 and 1")
    if clip_seconds <= 0:
        raise ValueError("clip_seconds must be positive")

    payload: dict[str, Any] = {
        "schemaVersion": "1.1",
        "eventId": event_id,
        "type": normalized_type,
        "occurredAt": occurred_at.isoformat(
            timespec="milliseconds"
        ).replace("+00:00", "Z"),
        "confidence": round(confidence, 6),
        "className": class_name,
        "preSeconds": clip_seconds,
        "postSeconds": clip_seconds,
    }
    if metadata:
        payload["metadata"] = metadata
    return payload


def write_audio_event_trigger(
    event_dir: Path,
    **payload_arguments: Any,
) -> Path:
    """Write a trigger with an atomic same-directory replacement."""

    event_dir.mkdir(parents=True, exist_ok=True)
    payload = build_audio_event_payload(**payload_arguments)
    destination = event_dir / f"{payload['eventId']}.trigger.json"
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    # 이름 바꾸기만으로는 부족하다. 내용이 디스크에 내려가기 전에 전원이 끊기면
    # ext4 는 이름만 살아남은 0바이트 파일을 남기고, 그 파일 하나가 업로더의
    # 트리거 스캔 전체를 막는다. 파일과 디렉터리를 모두 fsync 한다.
    with temporary.open("w", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(destination)
    fsync_directory(event_dir)
    return destination


def fsync_directory(directory: Path) -> None:
    """Flush a directory entry, skipping platforms that cannot open one."""

    try:
        handle = os.open(directory, os.O_RDONLY)
    except OSError:
        # 윈도우처럼 디렉터리를 열 수 없는 환경에서는 건너뛴다. 이 보호가
        # 필요한 곳은 젯슨(ext4)이다.
        return
    try:
        os.fsync(handle)
    except OSError:
        pass
    finally:
        os.close(handle)
