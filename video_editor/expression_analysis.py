"""Extract face blendshape reactions for expression-driven zoom planning."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

import cv2


def _clip(value: float) -> float:
    return max(0.0, min(1.0, float(value)))


def _resize_width(frame: Any, width: int) -> Any:
    if frame.shape[1] <= width:
        return frame
    height = max(1, round(frame.shape[0] * width / frame.shape[1]))
    return cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA)


def _face_reaction(
    blendshapes: list[Any], landmarks: list[Any]
) -> dict[str, Any]:
    scores = {str(item.category_name): float(item.score) for item in blendshapes}
    smile = (
        scores.get("mouthSmileLeft", 0.0) + scores.get("mouthSmileRight", 0.0)
    ) / 2.0
    eye_wide = (
        scores.get("eyeWideLeft", 0.0) + scores.get("eyeWideRight", 0.0)
    ) / 2.0
    eye_squint = (
        scores.get("eyeSquintLeft", 0.0) + scores.get("eyeSquintRight", 0.0)
    ) / 2.0
    jaw_open = scores.get("jawOpen", 0.0)
    brow_up = scores.get("browInnerUp", 0.0)
    surprise_raw = 0.40 * jaw_open + 0.30 * eye_wide + 0.30 * brow_up
    # Blendshape smiles commonly approach 1.0, while a visibly strong combined
    # surprise is much lower. Calibrate the two families before ranking faces.
    surprise = _clip(surprise_raw / 0.60)
    amusement = 0.75 * smile + 0.15 * eye_squint + 0.10 * jaw_open
    reaction = max(smile, amusement, surprise)
    dominant = "smile" if max(smile, amusement) >= surprise else "surprise"
    xs = [float(item.x) for item in landmarks]
    ys = [float(item.y) for item in landmarks]
    left = max(0.0, min(xs))
    right = min(1.0, max(xs))
    top = max(0.0, min(ys))
    bottom = min(1.0, max(ys))
    return {
        "reactionScore": _clip(reaction),
        "smileScore": _clip(smile),
        "amusementScore": _clip(amusement),
        "surpriseScore": _clip(surprise),
        "surpriseRawScore": _clip(surprise_raw),
        "jawOpenScore": _clip(jaw_open),
        "dominantExpression": dominant,
        "focusX": _clip((left + right) / 2.0),
        "focusY": _clip((top + bottom) / 2.0),
        "faceWidth": _clip(right - left),
        "faceHeight": _clip(bottom - top),
    }


def analyze_expressions(
    video_path: Path,
    model_path: Path,
    *,
    sample_interval_ms: int = 250,
    analysis_width: int = 640,
    max_faces: int = 4,
) -> dict[str, Any]:
    if sample_interval_ms <= 0:
        raise ValueError("sample_interval_ms must be positive")
    started = time.perf_counter()
    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        raise ValueError(f"cannot open video: {video_path}")
    fps = float(capture.get(cv2.CAP_PROP_FPS) or 0.0)
    frame_count = int(capture.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    duration_ms = round(frame_count / fps * 1000) if fps > 0.0 else 0

    import mediapipe as mp

    options = mp.tasks.vision.FaceLandmarkerOptions(
        base_options=mp.tasks.BaseOptions(model_asset_path=str(model_path)),
        running_mode=mp.tasks.vision.RunningMode.VIDEO,
        num_faces=max_faces,
        min_face_detection_confidence=0.30,
        min_face_presence_confidence=0.30,
        min_tracking_confidence=0.30,
        output_face_blendshapes=True,
    )
    windows: list[dict[str, Any]] = []
    try:
        with mp.tasks.vision.FaceLandmarker.create_from_options(options) as landmarker:
            timestamp_ms = 0
            while duration_ms <= 0 or timestamp_ms < duration_ms:
                capture.set(cv2.CAP_PROP_POS_MSEC, timestamp_ms)
                ok, frame = capture.read()
                if not ok:
                    break
                frame = _resize_width(frame, analysis_width)
                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                result = landmarker.detect_for_video(
                    mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), timestamp_ms
                )
                faces = [
                    _face_reaction(blendshapes, landmarks)
                    for blendshapes, landmarks in zip(
                        result.face_blendshapes, result.face_landmarks
                    )
                ]
                strongest = max(
                    faces, key=lambda item: float(item["reactionScore"]), default=None
                )
                # 검출된 얼굴 **전부**의 자리·크기. 최강 한 명으로 접어 버리면
                # 여러 명이 나올 때 초점이 사람 사이를 오가고, 얼굴 추적
                # 스티커가 누구를 따라갈지 정할 수 없다.
                face_boxes = [
                    {
                        "focusX": face["focusX"],
                        "focusY": face["focusY"],
                        "faceWidth": face["faceWidth"],
                        "faceHeight": face["faceHeight"],
                        "reactionScore": face["reactionScore"],
                    }
                    for face in faces
                ]
                row = {
                    "startMs": timestamp_ms,
                    "endMs": min(duration_ms, timestamp_ms + sample_interval_ms)
                    if duration_ms > 0
                    else timestamp_ms + sample_interval_ms,
                    "faceCount": len(faces),
                    "reactionScore": 0.0,
                    "smileScore": 0.0,
                    "amusementScore": 0.0,
                    "surpriseScore": 0.0,
                    "surpriseRawScore": 0.0,
                    "jawOpenScore": 0.0,
                    "dominantExpression": "none",
                    "focusX": 0.5,
                    "focusY": 0.5,
                    "faceWidth": 0.0,
                    "faceHeight": 0.0,
                    "faces": face_boxes,
                }
                if strongest is not None:
                    row.update(strongest)
                windows.append(row)
                timestamp_ms += sample_interval_ms
    finally:
        capture.release()
    if not windows:
        raise ValueError(f"video contains no decodable frames: {video_path}")
    if duration_ms <= 0:
        duration_ms = int(windows[-1]["endMs"])
    return {
        "analysisVersion": "expression-v3",
        "sourcePath": video_path.name,
        "durationMs": duration_ms,
        "sampleIntervalMs": sample_interval_ms,
        "expressionWindows": windows,
        "processingSeconds": round(time.perf_counter() - started, 3),
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("videos", type=Path, nargs="+")
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--sample-interval-ms", type=int, default=250)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for index, video_path in enumerate(args.videos, start=1):
        result = analyze_expressions(
            video_path,
            args.model,
            sample_interval_ms=args.sample_interval_ms,
        )
        output_path = args.output_dir / f"{video_path.stem}.expression.json"
        output_path.write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        sys.stderr.write(
            f"[{index}/{len(args.videos)}] {result['processingSeconds']}s -> {output_path}\n"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
