#!/usr/bin/env python3
"""Build laughter clips from rolling MPEG-TS segments and upload them."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import time
from typing import Any, Iterable
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit

from laughter_clip_uploader import (
    instant,
    request_json,
    sha256,
    upload_file,
)


SEGMENT_NAME_FORMAT = "homecam-%Y%m%dT%H%M%S.ts"
RETRYABLE_HTTP_STATUSES = frozenset({408, 425, 429})
TERMINAL_HTTP_STATUSES = frozenset({400, 401, 403, 404, 409, 410, 422})
MAX_ERROR_BODY_CHARACTERS = 2_048


class SegmentCoverageError(ValueError):
    """The rolling recording does not completely cover an event interval."""


@dataclass(frozen=True)
class Trigger:
    path: Path
    event_id: str
    occurred_at: datetime
    pre_seconds: float
    post_seconds: float


@dataclass(frozen=True)
class Segment:
    path: Path
    started_at: datetime


@dataclass(frozen=True)
class RetryState:
    attempts: int
    retry_at: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-dir", type=Path, required=True)
    parser.add_argument("--recording-dir", type=Path, required=True)
    parser.add_argument(
        "--api-base-url",
        default=os.getenv("API_BASE_URL", "https://i15e201.p.ssafy.io"),
    )
    parser.add_argument("--device-token", default=os.getenv("DEVICE_BEARER_TOKEN"))
    parser.add_argument("--ffmpeg", default=os.getenv("FFMPEG_PATH", "/usr/bin/ffmpeg"))
    parser.add_argument("--poll-seconds", type=float, default=1.0)
    parser.add_argument("--merge-gap-seconds", type=float, default=30.0)
    parser.add_argument("--segment-seconds", type=float, default=60.0)
    parser.add_argument(
        "--segment-finalize-seconds",
        type=float,
        default=3.0,
        help="Additional wait after the requested clip end (default: 3).",
    )
    parser.add_argument(
        "--retry-initial-seconds",
        type=float,
        default=5.0,
        help="Initial upload retry delay in seconds (default: 5).",
    )
    parser.add_argument(
        "--retry-max-seconds",
        type=float,
        default=300.0,
        help="Maximum upload retry delay in seconds (default: 300).",
    )
    parser.add_argument("--delete-after-upload", action="store_true")
    return parser.parse_args()


def parse_trigger(path: Path) -> Trigger:
    payload = json.loads(path.read_text(encoding="utf-8"))
    event_id = str(payload["eventId"])
    expected_id = path.name.removesuffix(".trigger.json")
    if event_id != expected_id:
        raise ValueError("trigger eventId does not match its filename")
    occurred_at = datetime.fromisoformat(
        str(payload["occurredAt"]).replace("Z", "+00:00")
    )
    if occurred_at.tzinfo is None:
        raise ValueError("occurredAt must include a timezone")
    pre_seconds = float(payload.get("preSeconds", 60.0))
    post_seconds = float(payload.get("postSeconds", 60.0))
    if pre_seconds <= 0 or post_seconds <= 0:
        raise ValueError("preSeconds and postSeconds must be positive")
    return Trigger(
        path=path,
        event_id=event_id,
        occurred_at=occurred_at.astimezone(timezone.utc),
        pre_seconds=pre_seconds,
        post_seconds=post_seconds,
    )


def group_triggers(
    triggers: Iterable[Trigger],
    merge_gap_seconds: float,
) -> list[list[Trigger]]:
    ordered = sorted(triggers, key=lambda trigger: trigger.occurred_at)
    groups: list[list[Trigger]] = []
    for trigger in ordered:
        if (
            not groups
            or (
                trigger.occurred_at - groups[-1][-1].occurred_at
            ).total_seconds()
            > merge_gap_seconds
        ):
            groups.append([trigger])
        else:
            groups[-1].append(trigger)
    return groups


def clip_interval(group: list[Trigger]) -> tuple[datetime, datetime]:
    if not group:
        raise ValueError("trigger group cannot be empty")
    start = min(
        trigger.occurred_at - timedelta(seconds=trigger.pre_seconds)
        for trigger in group
    )
    end = max(
        trigger.occurred_at + timedelta(seconds=trigger.post_seconds)
        for trigger in group
    )
    return start, end


def parse_segment(path: Path) -> Segment:
    started_at = datetime.strptime(path.name, SEGMENT_NAME_FORMAT).replace(
        tzinfo=timezone.utc
    )
    return Segment(path=path, started_at=started_at)


def select_completed_segments(
    paths: Iterable[Path],
    clip_start: datetime,
    clip_end: datetime,
    segment_seconds: float,
    *,
    timing_tolerance_seconds: float = 2.0,
) -> list[Segment]:
    """Select completed segments that continuously cover the requested range.

    The newest file is treated as active. A following segment therefore acts
    as the completion marker for the previous file.
    """

    segments = sorted(
        (parse_segment(path) for path in paths),
        key=lambda item: item.started_at,
    )
    if len(segments) < 2:
        raise SegmentCoverageError("waiting for a completed recording segment")

    completed = segments[:-1]
    selected: list[Segment] = []
    cursor = clip_start
    maximum_duration = segment_seconds + timing_tolerance_seconds

    for index, segment in enumerate(completed):
        next_start = segments[index + 1].started_at
        segment_end = min(
            segment.started_at + timedelta(seconds=maximum_duration),
            next_start,
        )
        if segment_end <= cursor:
            continue
        if segment.started_at > cursor + timedelta(seconds=timing_tolerance_seconds):
            raise SegmentCoverageError(
                f"recording gap before {segment.started_at.isoformat()}"
            )
        selected.append(segment)
        cursor = max(cursor, segment_end)
        if cursor >= clip_end:
            return selected

    raise SegmentCoverageError("waiting for recording coverage after the event")


def concat_line(path: Path) -> str:
    escaped = str(path.resolve()).replace("'", "'\\''")
    return f"file '{escaped}'\n"


def mux_segments(
    ffmpeg: str,
    segments: list[Segment],
    clip_start: datetime,
    clip_end: datetime,
    output_path: Path,
) -> None:
    concat_path = output_path.with_suffix(".concat.txt")
    temporary = output_path.with_name(output_path.stem + ".tmp.mp4")
    concat_path.write_text(
        "".join(concat_line(segment.path) for segment in segments),
        encoding="utf-8",
    )
    offset_seconds = max(
        0.0,
        (clip_start - segments[0].started_at).total_seconds(),
    )
    duration_seconds = max(0.001, (clip_end - clip_start).total_seconds())
    command = [
        ffmpeg,
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        str(concat_path),
        "-ss",
        f"{offset_seconds:.3f}",
        "-t",
        f"{duration_seconds:.3f}",
        "-map",
        "0:v:0",
        "-map",
        "0:a:0",
        "-c",
        "copy",
        "-movflags",
        "+faststart",
        str(temporary),
    ]
    try:
        subprocess.run(command, check=True)
        temporary.replace(output_path)
    finally:
        concat_path.unlink(missing_ok=True)
        temporary.unlink(missing_ok=True)


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False),
        encoding="utf-8",
    )
    temporary.replace(path)


def safe_endpoint(url: str) -> str:
    """Return an HTTP endpoint without credentials, query, or fragment."""

    parsed = urlsplit(url)
    host = parsed.hostname or ""
    if parsed.port is not None:
        host = f"{host}:{parsed.port}"
    return f"{parsed.scheme}://{host}{parsed.path}"


def http_error_body(error: HTTPError) -> str:
    """Read and bound an HTTP error body for logs and local diagnostics."""

    try:
        raw = error.read(MAX_ERROR_BODY_CHARACTERS + 1)
    except OSError:
        return ""
    text = raw.decode("utf-8", errors="replace")
    text = " ".join(text.split())
    if len(text) > MAX_ERROR_BODY_CHARACTERS:
        return text[:MAX_ERROR_BODY_CHARACTERS] + "…"
    return text


def is_retryable_http_status(status: int) -> bool:
    if status in RETRYABLE_HTTP_STATUSES:
        return True
    if status in TERMINAL_HTTP_STATUSES:
        return False
    return status >= 500


def retry_delay(
    attempts: int,
    initial_seconds: float,
    maximum_seconds: float,
) -> float:
    if attempts < 1:
        raise ValueError("attempts must be positive")
    return min(initial_seconds * (2 ** (attempts - 1)), maximum_seconds)


def write_upload_blocked(
    args: argparse.Namespace,
    group: list[Trigger],
    *,
    reason: str,
    http_status: int | None = None,
    endpoint: str | None = None,
    response_body: str = "",
) -> None:
    canonical = group[0]
    blocked_at = instant(datetime.now(timezone.utc))
    for trigger in group:
        write_json_atomic(
            args.event_dir / f"{trigger.event_id}.upload-blocked.json",
            {
                "eventId": trigger.event_id,
                "canonicalEventId": canonical.event_id,
                "blockedAt": blocked_at,
                "reason": reason,
                "httpStatus": http_status,
                "endpoint": endpoint,
                "responseBody": response_body,
                "retryable": False,
            },
        )


def upload_group(
    args: argparse.Namespace,
    group: list[Trigger],
    clip_start: datetime,
    clip_end: datetime,
    output_path: Path,
) -> dict[str, Any]:
    canonical = group[0]
    checksum = sha256(output_path)
    upload_request = {
        "sourceEventId": canonical.event_id,
        "triggerType": "LAUGHTER",
        "title": "웃음이 감지된 순간",
        "capturedStartAt": instant(clip_start),
        "capturedEndAt": instant(clip_end),
        "durationMs": max(
            1,
            int(round((clip_end - clip_start).total_seconds() * 1_000)),
        ),
        "contentType": "video/mp4",
        "sizeBytes": output_path.stat().st_size,
        "checksumSha256": checksum,
    }
    base_url = args.api_base_url.rstrip("/")
    response, _ = request_json(
        f"{base_url}/api/iot/videos/upload-url",
        "POST",
        args.device_token,
        upload_request,
        canonical.event_id,
    )
    if not response.get("alreadyCompleted"):
        etag = upload_file(
            response["uploadUrl"],
            output_path,
            {
                str(key): str(value)
                for key, value in response["requiredHeaders"].items()
            },
        )
        request_json(
            f"{base_url}/api/iot/videos/complete",
            "POST",
            args.device_token,
            {"videoId": response["videoId"], "objectETag": etag},
            canonical.event_id,
        )
    return response


def process_group(
    args: argparse.Namespace,
    group: list[Trigger],
    now: datetime,
) -> bool:
    clip_start, clip_end = clip_interval(group)
    if now < clip_end + timedelta(seconds=args.segment_finalize_seconds):
        return False

    segments = select_completed_segments(
        args.recording_dir.glob("homecam-*.ts"),
        clip_start,
        clip_end,
        args.segment_seconds,
    )
    canonical = group[0]
    output_path = args.event_dir / f"{canonical.event_id}.mp4"
    if not output_path.exists():
        mux_segments(
            args.ffmpeg,
            segments,
            clip_start,
            clip_end,
            output_path,
        )
    response = upload_group(args, group, clip_start, clip_end, output_path)
    uploaded_at = instant(datetime.now(timezone.utc))
    for trigger in group[1:]:
        write_json_atomic(
            args.event_dir / f"{trigger.event_id}.merged.json",
            {
                "eventId": trigger.event_id,
                "canonicalEventId": canonical.event_id,
                "videoId": response["videoId"],
                "mergedAt": uploaded_at,
            },
        )
    write_json_atomic(
        args.event_dir / f"{canonical.event_id}.uploaded.json",
        {
            "eventId": canonical.event_id,
            "videoId": response["videoId"],
            "uploadedAt": uploaded_at,
            "mergedEventIds": [trigger.event_id for trigger in group[1:]],
        },
    )
    print(
        f"Uploaded rolling laughter clip: event={canonical.event_id} "
        f"merged={len(group) - 1} video={response['videoId']}"
    )
    if args.delete_after_upload:
        output_path.unlink(missing_ok=True)
        for trigger in group:
            trigger.path.unlink(missing_ok=True)
    return True


def unhandled_triggers(event_dir: Path) -> list[Trigger]:
    triggers: list[Trigger] = []
    for path in event_dir.glob("*.trigger.json"):
        event_id = path.name.removesuffix(".trigger.json")
        if (event_dir / f"{event_id}.uploaded.json").exists():
            continue
        if (event_dir / f"{event_id}.merged.json").exists():
            continue
        if (event_dir / f"{event_id}.upload-blocked.json").exists():
            continue
        triggers.append(parse_trigger(path))
    return triggers


def validate_args(args: argparse.Namespace) -> None:
    if not args.device_token:
        raise SystemExit("DEVICE_BEARER_TOKEN or --device-token is required")
    for name in (
        "poll_seconds",
        "segment_seconds",
        "segment_finalize_seconds",
        "retry_initial_seconds",
        "retry_max_seconds",
    ):
        if getattr(args, name) <= 0:
            raise SystemExit(f"--{name.replace('_', '-')} must be positive")
    if args.retry_initial_seconds > args.retry_max_seconds:
        raise SystemExit(
            "--retry-initial-seconds cannot exceed --retry-max-seconds"
        )
    if args.merge_gap_seconds < 0:
        raise SystemExit("--merge-gap-seconds cannot be negative")
    if not (args.recording_dir / ".homecam-recordings").is_file():
        raise SystemExit(
            f"Recording safety marker is missing: "
            f"{args.recording_dir / '.homecam-recordings'}"
        )


def run(args: argparse.Namespace) -> None:
    validate_args(args)
    args.event_dir.mkdir(parents=True, exist_ok=True)
    print(f"Watching event triggers: {args.event_dir.resolve()}")
    print(f"Reading rolling segments: {args.recording_dir.resolve()}")
    retry_states: dict[str, RetryState] = {}
    while True:
        try:
            triggers = unhandled_triggers(args.event_dir)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
            print(f"Trigger scan failed: {error}")
            time.sleep(args.poll_seconds)
            continue

        for group in group_triggers(triggers, args.merge_gap_seconds):
            canonical_id = group[0].event_id
            retry_state = retry_states.get(canonical_id)
            monotonic_now = time.monotonic()
            if retry_state is not None and monotonic_now < retry_state.retry_at:
                continue
            try:
                process_group(args, group, datetime.now(timezone.utc))
                retry_states.pop(canonical_id, None)
            except SegmentCoverageError as error:
                print(f"Rolling clip pending for {group[0].event_id}: {error}")
            except HTTPError as error:
                body = http_error_body(error)
                endpoint = safe_endpoint(error.url)
                detail = (
                    f"HTTP {error.code} endpoint={endpoint}"
                    + (f" body={body}" if body else "")
                )
                if is_retryable_http_status(error.code):
                    previous_attempts = (
                        retry_state.attempts if retry_state is not None else 0
                    )
                    attempts = previous_attempts + 1
                    delay = retry_delay(
                        attempts,
                        args.retry_initial_seconds,
                        args.retry_max_seconds,
                    )
                    retry_states[canonical_id] = RetryState(
                        attempts=attempts,
                        retry_at=time.monotonic() + delay,
                    )
                    print(
                        f"Rolling clip retry scheduled for {canonical_id}: "
                        f"{detail} attempt={attempts} delay={delay:.1f}s"
                    )
                else:
                    write_upload_blocked(
                        args,
                        group,
                        reason="terminal HTTP response",
                        http_status=error.code,
                        endpoint=endpoint,
                        response_body=body,
                    )
                    retry_states.pop(canonical_id, None)
                    print(
                        f"Rolling clip upload blocked for {canonical_id}: "
                        f"{detail}; local files preserved"
                    )
            except (ValueError, KeyError, json.JSONDecodeError) as error:
                write_upload_blocked(
                    args,
                    group,
                    reason=f"{type(error).__name__}: {error}",
                )
                retry_states.pop(canonical_id, None)
                print(
                    f"Rolling clip upload blocked for {canonical_id}: "
                    f"{type(error).__name__}: {error}; local files preserved"
                )
            except (URLError, OSError, subprocess.CalledProcessError) as error:
                previous_attempts = (
                    retry_state.attempts if retry_state is not None else 0
                )
                attempts = previous_attempts + 1
                delay = retry_delay(
                    attempts,
                    args.retry_initial_seconds,
                    args.retry_max_seconds,
                )
                retry_states[canonical_id] = RetryState(
                    attempts=attempts,
                    retry_at=time.monotonic() + delay,
                )
                print(
                    f"Rolling clip retry scheduled for {canonical_id}: "
                    f"{type(error).__name__}: {error} "
                    f"attempt={attempts} delay={delay:.1f}s"
                )
        time.sleep(args.poll_seconds)


def main() -> None:
    try:
        run(parse_args())
    except KeyboardInterrupt:
        print("Stopped rolling laughter clip uploader.")


if __name__ == "__main__":
    main()
