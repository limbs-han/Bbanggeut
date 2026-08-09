"""Render a versioned edit recipe with FFmpeg, including optional zoom ramps."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

import cv2


def _ffmpeg_number(value: float) -> str:
    return f"{value:.6f}".rstrip("0").rstrip(".")


def _focus_expression(
    focus: float,
    key: str,
    segment: dict[str, Any],
    cut_start_ms: int,
    fps: float,
) -> str:
    """이 줌의 초점(0~1) 표현식. 얼굴을 따라가면 프레임에 따라 값이 바뀐다."""
    track = segment.get("focusTrack") or []
    if not track:
        return _ffmpeg_number(focus)
    expression = _ffmpeg_number(focus + float(track[0].get(key, 0.0)))
    for point in track[1:]:
        frame = _ffmpeg_number((int(point["ms"]) - cut_start_ms) / 1000.0 * fps)
        value = _ffmpeg_number(
            max(0.0, min(1.0, focus + float(point.get(key, 0.0))))
        )
        expression = f"if(gte(on,{frame}),{value},{expression})"
    return expression


def build_zoompan_filter(
    width: int,
    height: int,
    fps: float,
    cut_start_ms: int,
    zoom_segments: list[dict[str, Any]],
) -> str:
    zoom_expression = "1"
    x_expression = "(iw-iw/zoom)/2"
    y_expression = "(ih-ih/zoom)/2"
    for segment in reversed(zoom_segments):
        start = (int(segment["startMs"]) - cut_start_ms) / 1000.0
        end = (int(segment["endMs"]) - cut_start_ms) / 1000.0
        ramp = int(segment.get("rampMs", 0)) / 1000.0
        scale = float(segment["scale"])
        focus_x = float(segment.get("focusX", 0.5))
        focus_y = float(segment.get("focusY", 0.5))
        start_text = _ffmpeg_number(start * fps)
        end_text = _ffmpeg_number(end * fps)
        amount_text = _ffmpeg_number(scale - 1.0)
        if ramp <= 0.0:
            local_zoom = _ffmpeg_number(scale)
        else:
            ramp_text = _ffmpeg_number(ramp * fps)
            local_zoom = (
                f"1+{amount_text}*min(min((on-{start_text})/{ramp_text},"
                f"({end_text}-on)/{ramp_text}),1)"
            )
        condition = f"between(on,{start_text},{end_text})"
        zoom_expression = f"if({condition},{local_zoom},{zoom_expression})"
        # 사람을 따라가는 줌은 초점이 시간에 따라 움직인다. 키프레임마다
        # 값이 바뀌는 계단식 표현식으로 굽는다 — 앱(Media3)은 표본 사이를
        # 보간하지만, 이 CLI는 레시피를 눈으로 확인하는 용도라 계단이면 된다.
        focus_x_text = _focus_expression(focus_x, "dx", segment, cut_start_ms, fps)
        focus_y_text = _focus_expression(focus_y, "dy", segment, cut_start_ms, fps)
        local_x = (
            f"max(0,min(iw-iw/zoom,{focus_x_text}*iw-iw/zoom/2))"
        )
        local_y = (
            f"max(0,min(ih-ih/zoom,{focus_y_text}*ih-ih/zoom/2))"
        )
        x_expression = f"if({condition},{local_x},{x_expression})"
        y_expression = f"if({condition},{local_y},{y_expression})"
    return (
        f"zoompan=z='{zoom_expression}':x='{x_expression}':y='{y_expression}':"
        f"d=1:s={width}x{height}:fps={_ffmpeg_number(fps)}"
    )


def render_recipe(
    source_path: Path,
    recipe: dict[str, Any],
    output_path: Path,
    *,
    ffmpeg_path: str = "ffmpeg",
) -> None:
    capture = cv2.VideoCapture(str(source_path))
    if not capture.isOpened():
        raise ValueError(f"cannot open video: {source_path}")
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = float(capture.get(cv2.CAP_PROP_FPS) or 30.0)
    capture.release()
    cut = recipe["cut"]
    cut_start_ms = int(cut["startMs"])
    duration_ms = int(cut["durationMs"])
    zoom_segments = recipe.get("zoomSegments", []) if recipe.get("zoomEnabled") else []
    output_path.parent.mkdir(parents=True, exist_ok=True)
    video_filters: list[str] = []
    if zoom_segments:
        video_filters.append(
            build_zoompan_filter(width, height, fps, cut_start_ms, zoom_segments)
        )
    command = [
        ffmpeg_path,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-ss",
        _ffmpeg_number(cut_start_ms / 1000.0),
        "-i",
        str(source_path),
        "-t",
        _ffmpeg_number(duration_ms / 1000.0),
    ]
    if video_filters:
        command.extend(["-vf", ",".join(video_filters)])
    command.extend(
        [
            "-map",
            "0:v:0",
            "-map",
            "0:a:0?",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "23",
            "-c:a",
            "aac",
            "-b:a",
            "128k",
            "-movflags",
            "+faststart",
            str(output_path),
        ]
    )
    subprocess.run(command, check=True)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--recipe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--ffmpeg",
        default=os.environ.get("FFMPEG_PATH") or shutil.which("ffmpeg") or "ffmpeg",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    render_recipe(
        args.source,
        json.loads(args.recipe.read_text(encoding="utf-8")),
        args.output,
        ffmpeg_path=args.ffmpeg,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
