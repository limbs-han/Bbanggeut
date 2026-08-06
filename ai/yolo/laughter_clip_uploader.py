#!/usr/bin/env python3
"""Mux local YOLO/YAMNet event clips and upload them through the IoT API."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-dir", type=Path, required=True)
    parser.add_argument(
        "--api-base-url",
        default=os.getenv("API_BASE_URL", "https://i15e201.p.ssafy.io"),
    )
    parser.add_argument("--device-token", default=os.getenv("DEVICE_BEARER_TOKEN"))
    parser.add_argument("--ffmpeg", default=os.getenv("FFMPEG_PATH", "/usr/bin/ffmpeg"))
    parser.add_argument("--poll-seconds", type=float, default=1.0)
    parser.add_argument("--delete-after-upload", action="store_true")
    return parser.parse_args()


def parse_instant(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("occurredAt must include a timezone")
    return parsed.astimezone(timezone.utc)


def instant(value: datetime) -> str:
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def request_json(
    url: str,
    method: str,
    token: str,
    payload: dict[str, Any],
    idempotency_key: str,
) -> tuple[dict[str, Any], Any]:
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request = Request(
        url,
        data=body,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Idempotency-Key": idempotency_key,
        },
    )
    with urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8")), response.headers


def mux(ffmpeg: str, video_path: Path, audio_path: Path, output_path: Path) -> None:
    temporary = output_path.with_name(output_path.stem + ".tmp.mp4")
    command = [
        ffmpeg,
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(video_path),
        "-i",
        str(audio_path),
        "-map",
        "0:v:0",
        "-map",
        "1:a:0",
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-shortest",
        "-movflags",
        "+faststart",
        str(temporary),
    ]
    subprocess.run(command, check=True)
    temporary.replace(output_path)


def upload_file(url: str, path: Path, headers: dict[str, str]) -> str | None:
    request = Request(url, data=path.read_bytes(), method="PUT", headers=headers)
    with urlopen(request, timeout=120) as response:
        return response.headers.get("ETag")


def process_event(args: argparse.Namespace, trigger_path: Path) -> bool:
    event_id = trigger_path.name.removesuffix(".trigger.json")
    marker_path = args.event_dir / f"{event_id}.uploaded.json"
    if marker_path.exists():
        return True
    video_path = args.event_dir / f"{event_id}.video.mp4"
    audio_path = args.event_dir / f"{event_id}.audio.wav"
    if not video_path.exists() or not audio_path.exists():
        return False

    payload = json.loads(trigger_path.read_text(encoding="utf-8"))
    occurred_at = parse_instant(payload["occurredAt"])
    pre_seconds = float(payload.get("preSeconds", 5.0))
    post_seconds = float(payload.get("postSeconds", 5.0))
    captured_start = occurred_at - timedelta(seconds=pre_seconds)
    captured_end = occurred_at + timedelta(seconds=post_seconds)
    duration_ms = max(1, int(round((pre_seconds + post_seconds) * 1000)))

    final_path = args.event_dir / f"{event_id}.mp4"
    if not final_path.exists():
        mux(args.ffmpeg, video_path, audio_path, final_path)
    checksum = sha256(final_path)
    size_bytes = final_path.stat().st_size

    upload_request = {
        "sourceEventId": event_id,
        "triggerType": "LAUGHTER",
        # 서버가 감지 유형으로 제목을 다시 정하므로(VideoEventTypes.arrivalTitle)
        # 이 값은 화면에 뜨지 않는다. 그래도 서버와 같은 문구로 둔다 — 다르면
        # 로그를 읽는 사람이 두 이름 중 무엇이 진짜인지 매번 확인해야 한다.
        "title": "웃음이 담긴 순간",
        "capturedStartAt": instant(captured_start),
        "capturedEndAt": instant(captured_end),
        "durationMs": duration_ms,
        "contentType": "video/mp4",
        "sizeBytes": size_bytes,
        "checksumSha256": checksum,
    }
    base_url = args.api_base_url.rstrip("/")
    response, _ = request_json(
        f"{base_url}/api/iot/videos/upload-url",
        "POST",
        args.device_token,
        upload_request,
        event_id,
    )
    if not response.get("alreadyCompleted"):
        etag = upload_file(
            response["uploadUrl"],
            final_path,
            {str(key): str(value) for key, value in response["requiredHeaders"].items()},
        )
        request_json(
            f"{base_url}/api/iot/videos/complete",
            "POST",
            args.device_token,
            {"videoId": response["videoId"], "objectETag": etag},
            event_id,
        )

    marker = {
        "eventId": event_id,
        "videoId": response["videoId"],
        "uploadedAt": instant(datetime.now(timezone.utc)),
    }
    marker_path.write_text(json.dumps(marker), encoding="utf-8")
    print(f"Uploaded laughter clip: event={event_id} video={response['videoId']}")
    if args.delete_after_upload:
        for path in (trigger_path, video_path, audio_path, final_path):
            path.unlink(missing_ok=True)
    return True


def run(args: argparse.Namespace) -> None:
    if not args.device_token:
        raise SystemExit("DEVICE_BEARER_TOKEN or --device-token is required")
    if args.poll_seconds <= 0:
        raise SystemExit("--poll-seconds must be positive")
    args.event_dir.mkdir(parents=True, exist_ok=True)
    print(f"Watching laughter clips: {args.event_dir.resolve()}")
    while True:
        for trigger_path in args.event_dir.glob("*.trigger.json"):
            try:
                process_event(args, trigger_path)
            except (HTTPError, URLError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
                print(f"Clip upload pending for {trigger_path.name}: {error}")
        time.sleep(args.poll_seconds)


def main() -> None:
    try:
        run(parse_args())
    except KeyboardInterrupt:
        print("Stopped laughter clip uploader.")


if __name__ == "__main__":
    main()
