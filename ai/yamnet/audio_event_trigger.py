"""Atomic local trigger writer shared by audio event detectors."""

from __future__ import annotations

from datetime import datetime
import json
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
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    temporary.replace(destination)
    return destination
