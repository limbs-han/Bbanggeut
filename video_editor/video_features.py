"""Extract lightweight visual signals for highlight selection and reframing.

The analyzer samples low-rate frames instead of decoding every frame.  It uses
the same inexpensive families of signals exposed by common automatic editors:
frame-to-frame motion, content change, exposure/blur quality, and face framing.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path
from typing import Any

import cv2
import numpy as np


def _clip(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


def _resize_width(frame: np.ndarray, width: int) -> np.ndarray:
    if frame.shape[1] <= width:
        return frame
    height = max(1, round(frame.shape[0] * width / frame.shape[1]))
    return cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA)


def _content_change(previous_hsv: np.ndarray | None, hsv: np.ndarray) -> float:
    if previous_hsv is None:
        return 0.0
    hue_delta = cv2.absdiff(previous_hsv[:, :, 0], hsv[:, :, 0]).astype(np.float32)
    hue_delta = np.minimum(hue_delta, 180.0 - hue_delta) / 90.0
    saturation_delta = (
        cv2.absdiff(previous_hsv[:, :, 1], hsv[:, :, 1]).astype(np.float32)
        / 255.0
    )
    luminance_delta = (
        cv2.absdiff(previous_hsv[:, :, 2], hsv[:, :, 2]).astype(np.float32)
        / 255.0
    )
    return float(np.mean((hue_delta + saturation_delta + luminance_delta) / 3.0))


def _face_metrics(detections: list[Any], width: int, height: int) -> dict[str, float]:
    if not detections:
        return {
            "faceCount": 0,
            "facePresence": 0.0,
            "largestFaceArea": 0.0,
            "faceCenterX": 0.5,
            "faceCenterY": 0.5,
            "faceCenterScore": 0.0,
            "faceProminence": 0.0,
        }
    frame_area = max(1, width * height)
    largest = max(detections, key=lambda item: item.bounding_box.width * item.bounding_box.height)
    box = largest.bounding_box
    area = _clip(box.width * box.height / frame_area)
    center_x = (box.origin_x + box.width / 2.0) / max(1, width)
    center_y = (box.origin_y + box.height / 2.0) / max(1, height)
    center_distance = math.hypot(center_x - 0.5, center_y - 0.5) / math.hypot(0.5, 0.5)
    center_score = _clip(1.0 - center_distance)
    # About 8% of the frame is already a strong talking-head composition.
    size_score = _clip(math.sqrt(area / 0.08)) if area > 0.0 else 0.0
    return {
        "faceCount": len(detections),
        "facePresence": 1.0,
        "largestFaceArea": area,
        "faceCenterX": _clip(center_x),
        "faceCenterY": _clip(center_y),
        "faceCenterScore": center_score,
        "faceProminence": size_score * (0.65 + 0.35 * center_score),
        # 검출된 얼굴 **전부**의 자리·크기.
        #
        # **왜 전부 남기나**: 위의 `faceCenterX/Y`는 그 창에서 가장 큰 얼굴
        # 하나다. 여러 명이 비슷한 크기로 잡히면 창마다 "가장 큰 얼굴"이
        # 사람 사이를 오간다 — 실제로 한 영상에서 4~5.5초 동안 뒤쪽 사람이
        # 가장 큰 얼굴로 잡혀, 자동 줌의 얼굴 궤적이 그 자리에서 끊겼다.
        # 전부 남기면 궤적이 "누구인지"를 보고 고를 수 있다.
        "faces": [
            {
                "x": _clip(
                    (item.bounding_box.origin_x + item.bounding_box.width / 2.0)
                    / max(1, width)
                ),
                "y": _clip(
                    (item.bounding_box.origin_y + item.bounding_box.height / 2.0)
                    / max(1, height)
                ),
                "w": _clip(item.bounding_box.width / max(1, width)),
                "h": _clip(item.bounding_box.height / max(1, height)),
            }
            for item in sorted(
                detections,
                key=lambda item: item.bounding_box.width * item.bounding_box.height,
                reverse=True,
            )
        ],
    }


def normalize_video_windows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Convert video-relative raw measures into reusable unit interval scores."""

    if not rows:
        return []
    motion_scale = max(0.005, float(np.percentile([row["motionRaw"] for row in rows], 90)))
    change_scale = max(
        0.005, float(np.percentile([row["contentChangeRaw"] for row in rows], 95))
    )
    sharpness_scale = max(
        1.0, float(np.percentile([row["sharpnessRaw"] for row in rows], 75))
    )
    normalized: list[dict[str, Any]] = []
    recent_changes: list[float] = []
    previous_face_area = 0.0
    for row in rows:
        change_raw = float(row["contentChangeRaw"])
        local_baseline = float(np.median(recent_changes[-6:])) if recent_changes else 0.0
        adaptive_ratio = change_raw / max(0.005, local_baseline)
        scene_cut = (
            _clip((adaptive_ratio - 1.8) / 3.2) * _clip(change_raw / change_scale)
            if len(recent_changes) >= 4
            else 0.0
        )
        brightness = float(row["brightness"])
        exposure = _clip(1.0 - abs(brightness - 0.5) / 0.5)
        contrast = _clip(float(row["contrastRaw"]) / 0.25)
        sharpness = _clip(float(row["sharpnessRaw"]) / sharpness_scale)
        quality = 0.45 * exposure + 0.20 * contrast + 0.35 * sharpness
        face_area = float(row["largestFaceArea"])
        face_change = _clip(abs(face_area - previous_face_area) / 0.08)
        output = {
            key: value
            for key, value in row.items()
            if key not in {"motionRaw", "contentChangeRaw", "contrastRaw", "sharpnessRaw"}
        }
        output.update(
            {
                "motionScore": round(_clip(float(row["motionRaw"]) / motion_scale), 6),
                "contentChange": round(_clip(change_raw / change_scale), 6),
                "sceneCutScore": round(scene_cut, 6),
                "exposureScore": round(exposure, 6),
                "contrastScore": round(contrast, 6),
                "sharpnessScore": round(sharpness, 6),
                "visualQuality": round(quality, 6),
                "faceChange": round(face_change, 6),
            }
        )
        normalized.append(output)
        recent_changes.append(change_raw)
        previous_face_area = face_area
    return normalized


def analyze_video(
    video_path: Path,
    face_model_path: Path,
    *,
    sample_interval_ms: int = 500,
    analysis_width: int = 320,
    face_width: int = 640,
    min_face_confidence: float = 0.35,
) -> dict[str, Any]:
    if sample_interval_ms <= 0:
        raise ValueError("sample_interval_ms must be positive")
    started = time.perf_counter()
    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        raise ValueError(f"cannot open video: {video_path}")
    fps = float(capture.get(cv2.CAP_PROP_FPS) or 0.0)
    frame_count = int(capture.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
    duration_ms = round(frame_count / fps * 1000) if fps > 0.0 else 0

    import mediapipe as mp

    options = mp.tasks.vision.FaceDetectorOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=str(face_model_path)),
        running_mode=mp.tasks.vision.RunningMode.VIDEO,
        min_detection_confidence=min_face_confidence,
    )
    rows: list[dict[str, Any]] = []
    previous_gray: np.ndarray | None = None
    previous_hsv: np.ndarray | None = None
    try:
        with mp.tasks.vision.FaceDetector.create_from_options(options) as detector:
            timestamp_ms = 0
            while duration_ms <= 0 or timestamp_ms < duration_ms:
                capture.set(cv2.CAP_PROP_POS_MSEC, timestamp_ms)
                ok, frame = capture.read()
                if not ok:
                    break
                compact = _resize_width(frame, analysis_width)
                gray = cv2.cvtColor(compact, cv2.COLOR_BGR2GRAY)
                gray_blurred = cv2.GaussianBlur(gray, (9, 9), 0)
                hsv = cv2.cvtColor(compact, cv2.COLOR_BGR2HSV)
                motion_raw = (
                    float(np.mean(cv2.absdiff(previous_gray, gray_blurred))) / 255.0
                    if previous_gray is not None
                    else 0.0
                )
                face_frame = _resize_width(frame, face_width)
                rgb = cv2.cvtColor(face_frame, cv2.COLOR_BGR2RGB)
                result = detector.detect_for_video(
                    mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), timestamp_ms
                )
                face = _face_metrics(
                    result.detections, face_frame.shape[1], face_frame.shape[0]
                )
                row = {
                    "startMs": timestamp_ms,
                    "endMs": min(duration_ms, timestamp_ms + sample_interval_ms)
                    if duration_ms > 0
                    else timestamp_ms + sample_interval_ms,
                    "brightness": round(float(np.mean(gray)) / 255.0, 6),
                    "contrastRaw": float(np.std(gray)) / 255.0,
                    "sharpnessRaw": float(cv2.Laplacian(gray, cv2.CV_64F).var()),
                    "motionRaw": motion_raw,
                    "contentChangeRaw": _content_change(previous_hsv, hsv),
                    **face,
                }
                rows.append(row)
                previous_gray = gray_blurred
                previous_hsv = hsv
                timestamp_ms += sample_interval_ms
    finally:
        capture.release()
    if not rows:
        raise ValueError(f"video contains no decodable frames: {video_path}")
    if duration_ms <= 0:
        duration_ms = int(rows[-1]["endMs"])
    return {
        # v2부터 창마다 검출된 얼굴을 **전부** 남긴다(`faces`). 옛 분석은
        # 가장 큰 얼굴 하나뿐이라 궤적이 사람을 구분하지 못한다.
        "analysisVersion": "video-v2",
        "sourcePath": video_path.name,
        "durationMs": duration_ms,
        "sampleIntervalMs": sample_interval_ms,
        "videoMetadata": {
            "width": width,
            "height": height,
            "fps": round(fps, 6),
            "frameCount": frame_count,
        },
        "videoWindows": normalize_video_windows(rows),
        "processingSeconds": round(time.perf_counter() - started, 3),
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("videos", type=Path, nargs="+")
    parser.add_argument("--face-model", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--sample-interval-ms", type=int, default=500)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for index, video_path in enumerate(args.videos, start=1):
        analysis = analyze_video(
            video_path,
            args.face_model,
            sample_interval_ms=args.sample_interval_ms,
        )
        output_path = args.output_dir / f"{video_path.stem}.video.json"
        output_path.write_text(
            json.dumps(analysis, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        sys.stderr.write(
            f"[{index}/{len(args.videos)}] {analysis['processingSeconds']}s -> {output_path}\n"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
