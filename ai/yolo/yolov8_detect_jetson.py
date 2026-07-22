"""Run YOLOv8 person, cat, and dog detection on a Jetson camera.

The script defaults to headless operation so it can be launched over SSH.
Use --display only when a desktop display is available, and use --output to
write an annotated video for later download.
"""

from __future__ import annotations

import argparse
import os
import time
from collections import Counter
from pathlib import Path
from typing import Any

import cv2
import torch
from ultralytics import YOLO


BASE_DIR = Path(__file__).resolve().parent
DEFAULT_MODEL_PATH = BASE_DIR / "yolov8n.pt"

# COCO class IDs used by the pretrained yolov8n.pt model.
TARGET_CLASSES = {
    0: "person",
    15: "cat",
    16: "dog",
}
TARGET_CLASS_IDS = list(TARGET_CLASSES)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Detect only people, cats, and dogs with YOLOv8 on Jetson."
    )
    parser.add_argument(
        "--model",
        type=Path,
        default=DEFAULT_MODEL_PATH,
        help="Path to a YOLO .pt or TensorRT .engine model.",
    )
    parser.add_argument("--camera", type=int, default=0, help="V4L2 camera index.")
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--fps", type=int, default=30, help="Requested camera FPS.")
    parser.add_argument("--imgsz", type=int, default=640, help="YOLO input size.")
    parser.add_argument(
        "--confidence",
        type=float,
        default=0.35,
        help="Minimum detection confidence from 0 to 1.",
    )
    parser.add_argument(
        "--device",
        default="auto",
        help="Inference device: auto, cpu, or CUDA device number such as 0.",
    )
    parser.add_argument(
        "--half",
        action="store_true",
        help="Use FP16 for a PyTorch model on CUDA.",
    )
    parser.add_argument(
        "--display",
        action="store_true",
        help="Show an OpenCV window. Do not use over plain headless SSH.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Optional annotated output video path, for example output.mp4.",
    )
    parser.add_argument(
        "--max-frames",
        type=int,
        default=0,
        help="Stop after this many frames; 0 means run until Ctrl+C or q.",
    )
    args = parser.parse_args()

    if args.width < 1 or args.height < 1 or args.fps < 1 or args.imgsz < 1:
        parser.error("--width, --height, --fps, and --imgsz must be positive")
    if not 0.0 <= args.confidence <= 1.0:
        parser.error("--confidence must be between 0 and 1")
    if args.max_frames < 0:
        parser.error("--max-frames cannot be negative")
    return args


def choose_device(requested_device: str) -> int | str:
    if requested_device == "auto":
        return 0 if torch.cuda.is_available() else "cpu"
    if requested_device == "cpu":
        return "cpu"
    try:
        cuda_index = int(requested_device)
    except ValueError as exc:
        raise SystemExit("--device must be auto, cpu, or a CUDA index such as 0") from exc
    if not torch.cuda.is_available():
        raise SystemExit("CUDA was requested but torch.cuda.is_available() is False.")
    return cuda_index


def open_camera(camera_index: int, width: int, height: int, fps: int) -> Any:
    capture = cv2.VideoCapture(camera_index, cv2.CAP_V4L2)
    if not capture.isOpened():
        capture.release()
        capture = cv2.VideoCapture(camera_index)
    if not capture.isOpened():
        raise SystemExit(
            f"Could not open /dev/video{camera_index}. Check the camera index and permissions."
        )

    # MJPG lets common USB webcams such as the Logitech Brio provide higher
    # resolutions without sending uncompressed frames over USB.
    capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    capture.set(cv2.CAP_PROP_FPS, fps)
    capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    return capture


def create_writer(output_path: Path, frame: Any, fps: float) -> Any:
    output_path = output_path.expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    height, width = frame.shape[:2]
    writer = cv2.VideoWriter(
        str(output_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        (width, height),
    )
    if not writer.isOpened():
        raise SystemExit(f"Could not create output video: {output_path}")
    print(f"Annotated video: {output_path}")
    return writer


def detection_summary(result: Any) -> str:
    if result.boxes is None or len(result.boxes) == 0:
        return "none"

    counts: Counter[str] = Counter()
    best_scores: dict[str, float] = {}
    for class_tensor, confidence_tensor in zip(result.boxes.cls, result.boxes.conf):
        class_id = int(class_tensor.item())
        class_name = TARGET_CLASSES.get(class_id, str(class_id))
        confidence = float(confidence_tensor.item())
        counts[class_name] += 1
        best_scores[class_name] = max(best_scores.get(class_name, 0.0), confidence)

    return ", ".join(
        f"{name}={count} (best {best_scores[name]:.2f})"
        for name, count in sorted(counts.items())
    )


def run(args: argparse.Namespace) -> None:
    model_path = args.model.expanduser().resolve()
    if not model_path.is_file():
        raise SystemExit(f"Model file not found: {model_path}")
    if args.display and os.name != "nt" and not os.environ.get("DISPLAY"):
        raise SystemExit(
            "--display was requested, but DISPLAY is not set. "
            "Run without --display over SSH and use --output instead."
        )

    device = choose_device(args.device)
    model = YOLO(str(model_path))
    capture = open_camera(args.camera, args.width, args.height, args.fps)
    writer = None
    frame_count = 0
    started_at = time.monotonic()
    last_report_at = started_at

    actual_width = int(capture.get(cv2.CAP_PROP_FRAME_WIDTH))
    actual_height = int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    actual_fps = capture.get(cv2.CAP_PROP_FPS)
    if actual_fps <= 0:
        actual_fps = float(args.fps)

    print(f"Model: {model_path}")
    print(f"Device: {device}")
    if device != "cpu":
        print(f"CUDA device: {torch.cuda.get_device_name(int(device))}")
    print(f"Camera: /dev/video{args.camera} ({actual_width}x{actual_height} @ {actual_fps:.1f} FPS)")
    print("Classes: person, cat, dog")
    print("Press Ctrl+C to stop" + (", or q in the display window." if args.display else "."))

    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                raise SystemExit("The camera opened, but a frame could not be read.")

            results = model.predict(
                source=frame,
                device=device,
                classes=TARGET_CLASS_IDS,
                conf=args.confidence,
                imgsz=args.imgsz,
                half=args.half and device != "cpu" and model_path.suffix == ".pt",
                verbose=False,
            )
            result = results[0]
            annotated_frame = result.plot()
            frame_count += 1

            if args.output is not None:
                if writer is None:
                    writer = create_writer(args.output, annotated_frame, actual_fps)
                writer.write(annotated_frame)

            now = time.monotonic()
            if now - last_report_at >= 1.0:
                average_fps = frame_count / max(now - started_at, 1e-6)
                print(
                    f"frames={frame_count}  average_FPS={average_fps:.1f}  "
                    f"detections: {detection_summary(result)}"
                )
                last_report_at = now

            if args.display:
                cv2.imshow("YOLOv8 Jetson - person, cat, dog", annotated_frame)
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    break

            if args.max_frames and frame_count >= args.max_frames:
                break
    except KeyboardInterrupt:
        print("\nStopped by user.")
    finally:
        capture.release()
        if writer is not None:
            writer.release()
        cv2.destroyAllWindows()

    elapsed = max(time.monotonic() - started_at, 1e-6)
    print(f"Finished: {frame_count} frames, average {frame_count / elapsed:.1f} FPS")


def main() -> None:
    run(parse_args())


if __name__ == "__main__":
    main()
