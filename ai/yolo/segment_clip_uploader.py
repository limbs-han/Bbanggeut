#!/usr/bin/env python3
"""Build laughter clips from rolling MPEG-TS segments and upload them."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import shutil
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
KEYFRAME_PROBE_TIMEOUT_SECONDS = 30
MIXED_EVENT_TITLES = {
    frozenset({"LAUGHTER", "CLAP"}): "웃음과 박수가 함께 포착됐어요",
}
EVENT_TYPE_PRIORITY = {
    "LAUGHTER": 0,
    "CLAP": 1,
    "WAKE_WORD": 2,
}
EVENT_TITLES = {
    "LAUGHTER": "웃음이 담긴 순간",
    "CLAP": "박수가 시작된 순간",
    "WAKE_WORD": "카메라를 부른 순간",
}


class SegmentCoverageError(ValueError):
    """The rolling recording does not completely cover an event interval."""


@dataclass(frozen=True)
class Trigger:
    path: Path
    event_id: str
    occurred_at: datetime
    pre_seconds: float
    post_seconds: float
    event_type: str = "LAUGHTER"


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
    parser.add_argument(
        "--cross-type-merge-gap-seconds",
        type=float,
        default=5.0,
        help=(
            "Merge LAUGHTER and CLAP triggers within this many seconds "
            "into one uploaded event (default: 5)."
        ),
    )
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
    event_type = str(payload.get("type", "LAUGHTER")).strip().upper()
    if event_type not in EVENT_TITLES:
        raise ValueError(f"unsupported trigger type: {event_type}")
    return Trigger(
        path=path,
        event_id=event_id,
        occurred_at=occurred_at.astimezone(timezone.utc),
        pre_seconds=pre_seconds,
        post_seconds=post_seconds,
        event_type=event_type,
    )


def group_triggers(
    triggers: Iterable[Trigger],
    merge_gap_seconds: float,
    cross_type_merge_gap_seconds: float = 5.0,
) -> list[list[Trigger]]:
    """Group repeated events and near-simultaneous laughter with clapping.

    Repeated triggers of the same type keep the existing merge window. Only
    LAUGHTER and CLAP are eligible for the shorter cross-type window; wake-name
    events remain independent from unrelated sounds.
    """

    groups: list[list[Trigger]] = []
    ordered = sorted(triggers, key=lambda trigger: trigger.occurred_at)
    for trigger in ordered:
        matching_group: list[Trigger] | None = None
        for group in reversed(groups):
            same_type_times = [
                item.occurred_at
                for item in group
                if item.event_type == trigger.event_type
            ]
            if same_type_times:
                same_type_gap = (
                    trigger.occurred_at - max(same_type_times)
                ).total_seconds()
                if same_type_gap <= merge_gap_seconds:
                    matching_group = group
                    break

            opposite_times = [
                item.occurred_at
                for item in group
                if {item.event_type, trigger.event_type}
                == {"LAUGHTER", "CLAP"}
            ]
            if opposite_times:
                cross_type_gap = (
                    trigger.occurred_at - max(opposite_times)
                ).total_seconds()
                if cross_type_gap <= cross_type_merge_gap_seconds:
                    matching_group = group
                    break

        if matching_group is None:
            groups.append([trigger])
        else:
            matching_group.append(trigger)
    return groups


def event_types(group: list[Trigger]) -> tuple[str, ...]:
    """Return unique event types in stable presentation order."""

    return tuple(
        sorted(
            {trigger.event_type for trigger in group},
            key=lambda event_type: (
                EVENT_TYPE_PRIORITY.get(event_type, len(EVENT_TYPE_PRIORITY)),
                event_type,
            ),
        )
    )


def canonical_trigger(group: list[Trigger]) -> Trigger:
    """Choose the event ID used for one upload.

    LAUGHTER remains canonical for a mixed laughter-and-clap event so rollout
    stays compatible with servers that only know the original trigger type.
    """

    if not group:
        raise ValueError("trigger group cannot be empty")
    return min(
        group,
        key=lambda trigger: (
            EVENT_TYPE_PRIORITY.get(
                trigger.event_type,
                len(EVENT_TYPE_PRIORITY),
            ),
            trigger.occurred_at,
            trigger.event_id,
        ),
    )


def merged_triggers(group: list[Trigger]) -> list[Trigger]:
    canonical = canonical_trigger(group)
    return [trigger for trigger in group if trigger is not canonical]


def event_title(group: list[Trigger]) -> str:
    types = frozenset(event_types(group))
    if types in MIXED_EVENT_TITLES:
        return MIXED_EVENT_TITLES[types]
    return EVENT_TITLES[canonical_trigger(group).event_type]


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
    """Interpret recording filenames in the UTC configured by the recorder."""

    naive = datetime.strptime(path.name, SEGMENT_NAME_FORMAT)
    started_at = naive.replace(tzinfo=timezone.utc)
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


def ffprobe_path(ffmpeg: str) -> str:
    sibling = Path(ffmpeg).with_name("ffprobe")
    if sibling.exists():
        return str(sibling)
    return shutil.which("ffprobe") or "ffprobe"


def keyframe_offset(ffmpeg: str, concat_path: Path, offset_seconds: float) -> float:
    """Snap a cut point back to the video keyframe at or before it.

    `-ss` after `-i` is an output seek, and with `-c copy` ffmpeg cannot start
    the video stream mid-GOP: it drops packets until the next keyframe while
    audio starts at the requested instant. The clip then opens with the video
    trailing the audio by however far that keyframe was, which is anywhere in
    0..GOP seconds and therefore differs per clip.

    Cutting exactly on a keyframe removes that gap, so probe for one instead of
    trusting the raw offset. Snapping backwards (never forwards) keeps the
    event inside the clip. Returns the original offset when probing fails, which
    only restores the previous behaviour rather than dropping the clip.
    """
    if offset_seconds <= 0:
        return 0.0
    command = [
        ffprobe_path(ffmpeg),
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        str(concat_path),
        "-select_streams",
        "v:0",
        # Packet flags are enough to find keyframes and avoid decoding frames.
        "-show_entries",
        "packet=pts_time,flags",
        "-of",
        "csv=p=0",
        # Reading past the cut point is wasted work on a 60s pre-roll.
        "-read_intervals",
        f"%+{offset_seconds + 1:.3f}",
    ]
    try:
        completed = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=KEYFRAME_PROBE_TIMEOUT_SECONDS,
        )
    except (subprocess.SubprocessError, OSError):
        return offset_seconds
    best = None
    for line in completed.stdout.splitlines():
        fields = line.split(",")
        if len(fields) < 2 or "K" not in fields[1]:
            continue
        try:
            pts = float(fields[0])
        except ValueError:
            continue
        if pts <= offset_seconds and (best is None or pts > best):
            best = pts
    return offset_seconds if best is None else best


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
    offset_seconds = keyframe_offset(
        ffmpeg,
        concat_path,
        max(0.0, (clip_start - segments[0].started_at).total_seconds()),
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


def write_upload_status(
    args: argparse.Namespace,
    group: list[Trigger],
    status: str,
    detail: str,
    **fields: Any,
) -> None:
    """Persist the latest safe-to-display upload state for the dashboard."""

    canonical = canonical_trigger(group)
    merged = merged_triggers(group)
    path = args.event_dir / f"{canonical.event_id}.upload-status.json"
    updated_at = instant(datetime.now(timezone.utc))
    payload = {
        "eventId": canonical.event_id,
        "canonicalEventId": canonical.event_id,
        "mergedEventIds": [trigger.event_id for trigger in merged],
        "eventTypes": list(event_types(group)),
        "status": status,
        "detail": detail,
        "updatedAt": updated_at,
        **fields,
    }
    try:
        previous: dict[str, Any] = {}
        if path.exists():
            previous = json.loads(path.read_text(encoding="utf-8"))
            comparable = {
                key: value
                for key, value in payload.items()
                if key not in {"updatedAt", "history"}
            }
            if all(previous.get(key) == value for key, value in comparable.items()):
                return
        history = previous.get("history", [])
        if not isinstance(history, list):
            history = []
        payload["history"] = [
            *history[-99:],
            {
                "status": status,
                "detail": detail,
                "updatedAt": updated_at,
                **fields,
            },
        ]
        write_json_atomic(path, payload)
    except (OSError, json.JSONDecodeError):
        # Status reporting must never block the actual upload pipeline.
        return


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
    canonical = canonical_trigger(group)
    blocked_at = instant(datetime.now(timezone.utc))
    for trigger in group:
        write_json_atomic(
            args.event_dir / f"{trigger.event_id}.upload-blocked.json",
            {
                "eventId": trigger.event_id,
                "canonicalEventId": canonical.event_id,
                "eventTypes": list(event_types(group)),
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
    canonical = canonical_trigger(group)
    checksum = sha256(output_path)
    upload_request = {
        "sourceEventId": canonical.event_id,
        "triggerType": canonical.event_type,
        "eventTypes": list(event_types(group)),
        "title": event_title(group),
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
    write_upload_status(
        args,
        group,
        "REQUESTING_UPLOAD",
        "백엔드 업로드 URL 요청 중",
    )
    response, _ = request_json(
        f"{base_url}/api/iot/videos/upload-url",
        "POST",
        args.device_token,
        upload_request,
        canonical.event_id,
    )
    if not response.get("alreadyCompleted"):
        write_upload_status(
            args,
            group,
            "UPLOADING",
            "오브젝트 스토리지로 영상 전송 중",
            videoId=response["videoId"],
        )
        etag = upload_file(
            response["uploadUrl"],
            output_path,
            {
                str(key): str(value)
                for key, value in response["requiredHeaders"].items()
            },
        )
        write_upload_status(
            args,
            group,
            "COMPLETING",
            "백엔드 업로드 완료 처리 중",
            videoId=response["videoId"],
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
    canonical = canonical_trigger(group)
    merged = merged_triggers(group)
    output_path = args.event_dir / f"{canonical.event_id}.mp4"
    if not output_path.exists():
        write_upload_status(
            args,
            group,
            "BUILDING_CLIP",
            "녹화 세그먼트에서 웃음 영상을 생성 중",
        )
        mux_segments(
            args.ffmpeg,
            segments,
            clip_start,
            clip_end,
            output_path,
        )
    response = upload_group(args, group, clip_start, clip_end, output_path)
    uploaded_at = instant(datetime.now(timezone.utc))
    for trigger in merged:
        write_json_atomic(
            args.event_dir / f"{trigger.event_id}.merged.json",
            {
                "eventId": trigger.event_id,
                "canonicalEventId": canonical.event_id,
                "videoId": response["videoId"],
                "mergedAt": uploaded_at,
                "eventTypes": list(event_types(group)),
            },
        )
    write_json_atomic(
        args.event_dir / f"{canonical.event_id}.uploaded.json",
        {
            "eventId": canonical.event_id,
            "videoId": response["videoId"],
            "uploadedAt": uploaded_at,
            "mergedEventIds": [trigger.event_id for trigger in merged],
            "eventTypes": list(event_types(group)),
        },
    )
    write_upload_status(
        args,
        group,
        "UPLOADED",
        "영상 업로드 완료",
        videoId=response["videoId"],
    )
    print(
        f"Uploaded rolling event clip: event={canonical.event_id} "
        f"types={','.join(event_types(group))} "
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
    if args.cross_type_merge_gap_seconds < 0:
        raise SystemExit(
            "--cross-type-merge-gap-seconds cannot be negative"
        )
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

        for group in group_triggers(
            triggers,
            args.merge_gap_seconds,
            args.cross_type_merge_gap_seconds,
        ):
            canonical_id = canonical_trigger(group).event_id
            retry_state = retry_states.get(canonical_id)
            monotonic_now = time.monotonic()
            if retry_state is not None and monotonic_now < retry_state.retry_at:
                continue
            try:
                process_group(args, group, datetime.now(timezone.utc))
                retry_states.pop(canonical_id, None)
            except SegmentCoverageError as error:
                write_upload_status(
                    args,
                    group,
                    "WAITING_RECORDING",
                    str(error),
                )
                print(f"Rolling clip pending for {canonical_id}: {error}")
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
                    write_upload_status(
                        args,
                        group,
                        "RETRYING",
                        detail,
                        attempts=attempts,
                        retryDelaySeconds=delay,
                        httpStatus=error.code,
                        endpoint=endpoint,
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
                    write_upload_status(
                        args,
                        group,
                        "BLOCKED",
                        detail,
                        httpStatus=error.code,
                        endpoint=endpoint,
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
                write_upload_status(
                    args,
                    group,
                    "BLOCKED",
                    f"{type(error).__name__}: {error}",
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
                write_upload_status(
                    args,
                    group,
                    "RETRYING",
                    f"{type(error).__name__}: {error}",
                    attempts=attempts,
                    retryDelaySeconds=delay,
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
