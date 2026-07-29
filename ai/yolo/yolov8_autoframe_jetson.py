"""Track people, cats, and dogs and calculate a pan/tilt framing target.

This process does not write PWM directly. It uses YOLO and ByteTrack, draws the
chosen group and camera command on the video, and publishes normalized control
commands for the separate local servo controller.
"""

from __future__ import annotations

import argparse
from collections import deque
import json
import math
import os
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, TextIO

import cv2
import torch
from ultralytics import YOLO

from stream_capture import LatestFrameCapture, redact_stream_url


BASE_DIR = Path(__file__).resolve().parent
DEFAULT_MODEL_PATH = BASE_DIR / "yolov8n.pt"

# COCO class IDs for the pretrained YOLOv8 model.
TARGET_CLASSES = {0: "person", 15: "cat", 16: "dog"}
TARGET_CLASS_IDS = list(TARGET_CLASSES)

Point = tuple[float, float]
Box = tuple[float, float, float, float]


@dataclass(frozen=True)
class TrackedObject:
    track_id: int
    class_id: int
    class_name: str
    confidence: float
    box: Box

    @property
    def center(self) -> Point:
        x1, y1, x2, y2 = self.box
        return ((x1 + x2) / 2.0, (y1 + y2) / 2.0)


@dataclass
class TrackLife:
    consecutive_frames: int
    last_frame: int


@dataclass(frozen=True)
class FramingDecision:
    objects: tuple[TrackedObject, ...]
    group_box: Box
    raw_center: Point
    limited_group: bool
    total_stable_objects: int


@dataclass(frozen=True)
class CameraCommand:
    state: str
    direction: str
    command_x: str
    command_y: str
    target_ids: tuple[int, ...]
    target_count: int
    total_stable_objects: int
    center_x: float | None
    center_y: float | None
    error_x: float
    error_y: float
    group_box: tuple[float, float, float, float] | None
    limited_group: bool

    def as_payload(self, frame_index: int) -> dict[str, Any]:
        payload = asdict(self)
        payload["target_ids"] = list(self.target_ids)
        payload["frame_index"] = frame_index
        sent_at = (
            datetime.now(timezone.utc)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z")
        )
        payload["schema_version"] = "1.1"
        payload["sequence"] = frame_index
        payload["sent_at"] = sent_at
        payload["ttl_ms"] = 500
        payload["created_at"] = sent_at
        payload["monotonic_ns"] = time.monotonic_ns()
        return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Track people, cats, and dogs and simulate the best pan/tilt framing target."
        )
    )
    parser.add_argument(
        "--model",
        type=Path,
        default=DEFAULT_MODEL_PATH,
        help="Path to a YOLO .pt or TensorRT .engine model.",
    )
    parser.add_argument("--camera", type=int, default=0, help="V4L2 camera index.")
    parser.add_argument(
        "--stream-url",
        default=os.getenv("YOLO_SOURCE_URL"),
        help="Shared RTSP/UDP stream URL. When set, --camera is ignored.",
    )
    parser.add_argument(
        "--reconnect-initial-seconds",
        type=float,
        default=float(os.getenv("STREAM_RECONNECT_INITIAL_SECONDS", "1")),
        help="Initial stream reconnect delay in seconds (default: 1).",
    )
    parser.add_argument(
        "--reconnect-max-seconds",
        type=float,
        default=float(os.getenv("STREAM_RECONNECT_MAX_SECONDS", "10")),
        help="Maximum stream reconnect delay in seconds (default: 10).",
    )
    parser.add_argument(
        "--stream-open-timeout-seconds",
        type=float,
        default=float(os.getenv("STREAM_OPEN_TIMEOUT_SECONDS", "5")),
        help="Network stream open timeout in seconds (default: 5).",
    )
    parser.add_argument(
        "--stream-read-timeout-seconds",
        type=float,
        default=float(os.getenv("STREAM_READ_TIMEOUT_SECONDS", "5")),
        help="Network stream read timeout in seconds (default: 5).",
    )
    parser.add_argument(
        "--video",
        type=Path,
        help="Optional input video. When set, --camera is ignored.",
    )
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
        help="Inference device: auto, cpu, or a CUDA index such as 0.",
    )
    parser.add_argument(
        "--half",
        action="store_true",
        help="Use FP16 for a PyTorch model on CUDA.",
    )
    parser.add_argument(
        "--tracker",
        default="bytetrack.yaml",
        help="Ultralytics tracker configuration (default: bytetrack.yaml).",
    )
    parser.add_argument(
        "--min-track-frames",
        type=int,
        default=3,
        help="Frames a track must persist before it affects framing.",
    )
    parser.add_argument(
        "--switch-frames",
        type=int,
        default=5,
        help="Frames a new best group must persist before switching to it.",
    )
    parser.add_argument(
        "--edge-margin",
        type=float,
        default=0.10,
        help="Reserved margin on each frame edge, as a ratio (default: 0.10).",
    )
    parser.add_argument(
        "--deadzone-width",
        type=float,
        default=0.12,
        help="Center dead-zone width as a frame ratio.",
    )
    parser.add_argument(
        "--deadzone-height",
        type=float,
        default=0.12,
        help="Center dead-zone height as a frame ratio.",
    )
    parser.add_argument(
        "--ema-alpha",
        type=float,
        default=0.25,
        help="Target smoothing strength from 0 (slow) to 1 (immediate).",
    )
    parser.add_argument(
        "--home-after-seconds",
        type=float,
        default=5.0,
        help="Hold after losing all targets, then emit a HOME command.",
    )
    parser.add_argument(
        "--command-interval",
        type=float,
        default=0.10,
        help="Minimum seconds between JSONL/MQTT commands (default: 10 Hz).",
    )
    parser.add_argument(
        "--control-output",
        type=Path,
        help="Optional JSON Lines path for normalized camera commands.",
    )
    parser.add_argument(
        "--mqtt-host",
        default=os.getenv("MQTT_HOST"),
        help="Optional MQTT broker host for publishing the current vision state.",
    )
    parser.add_argument(
        "--mqtt-port",
        type=int,
        default=int(os.getenv("MQTT_PORT", "1883")),
        help="MQTT broker port (default: 1883).",
    )
    parser.add_argument("--mqtt-username", default=os.getenv("MQTT_USERNAME"))
    parser.add_argument("--mqtt-password", default=os.getenv("MQTT_PASSWORD"))
    parser.add_argument(
        "--device-id",
        default=os.getenv("DEVICE_ID", "homecam-001"),
        help="Home camera device ID included in the vision state.",
    )
    parser.add_argument(
        "--mqtt-topic",
        help="Optional vision-state topic override.",
    )
    parser.add_argument(
        "--control-mqtt-topic",
        help="Optional servo-target topic override.",
    )
    parser.add_argument(
        "--display",
        action="store_true",
        help="Show an OpenCV window. Do not use over plain headless SSH.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Optional annotated output video path, for example autoframe.mp4.",
    )
    parser.add_argument(
        "--max-frames",
        type=int,
        default=0,
        help="Stop after this many frames; 0 means run until Ctrl+C or video end.",
    )
    parser.add_argument(
        "--event-dir",
        type=Path,
        help="Watch local laughter triggers and save matching camera clips.",
    )
    parser.add_argument(
        "--clip-seconds",
        type=float,
        default=5.0,
        help="Seconds to retain before and after an event (default: 5).",
    )
    args = parser.parse_args()

    if args.width < 1 or args.height < 1 or args.fps < 1 or args.imgsz < 1:
        parser.error("--width, --height, --fps, and --imgsz must be positive")
    if not 0.0 <= args.confidence <= 1.0:
        parser.error("--confidence must be between 0 and 1")
    if args.min_track_frames < 1 or args.switch_frames < 1:
        parser.error("--min-track-frames and --switch-frames must be at least 1")
    if not 0.0 <= args.edge_margin < 0.45:
        parser.error("--edge-margin must be at least 0 and less than 0.45")
    if not 0.0 <= args.deadzone_width < 1.0:
        parser.error("--deadzone-width must be between 0 and 1")
    if not 0.0 <= args.deadzone_height < 1.0:
        parser.error("--deadzone-height must be between 0 and 1")
    if not 0.0 < args.ema_alpha <= 1.0:
        parser.error("--ema-alpha must be greater than 0 and at most 1")
    if args.home_after_seconds < 0:
        parser.error("--home-after-seconds cannot be negative")
    if args.command_interval <= 0:
        parser.error("--command-interval must be positive")
    if not 1 <= args.mqtt_port <= 65_535:
        parser.error("--mqtt-port must be between 1 and 65535")
    if not args.device_id.strip():
        parser.error("--device-id cannot be empty")
    if args.max_frames < 0:
        parser.error("--max-frames cannot be negative")
    if args.clip_seconds <= 0:
        parser.error("--clip-seconds must be positive")
    if args.reconnect_initial_seconds <= 0:
        parser.error("--reconnect-initial-seconds must be positive")
    if args.reconnect_max_seconds < args.reconnect_initial_seconds:
        parser.error(
            "--reconnect-max-seconds must be at least --reconnect-initial-seconds"
        )
    if args.stream_open_timeout_seconds <= 0:
        parser.error("--stream-open-timeout-seconds must be positive")
    if args.stream_read_timeout_seconds <= 0:
        parser.error("--stream-read-timeout-seconds must be positive")
    return args


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(value, high))


def union_box(objects: Iterable[TrackedObject]) -> Box:
    items = tuple(objects)
    if not items:
        raise ValueError("union_box requires at least one object")
    return (
        min(item.box[0] for item in items),
        min(item.box[1] for item in items),
        max(item.box[2] for item in items),
        max(item.box[3] for item in items),
    )


def box_center(box: Box) -> Point:
    return ((box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0)


def box_fits(box: Box, max_width: float, max_height: float) -> bool:
    return box[2] - box[0] <= max_width and box[3] - box[1] <= max_height


def make_decision(
    selected: Iterable[TrackedObject],
    total_stable_objects: int,
) -> FramingDecision:
    items = tuple(sorted(selected, key=lambda item: item.track_id))
    group_box = union_box(items)
    return FramingDecision(
        objects=items,
        group_box=group_box,
        raw_center=box_center(group_box),
        limited_group=len(items) < total_stable_objects,
        total_stable_objects=total_stable_objects,
    )


def choose_best_group(
    objects: Iterable[TrackedObject],
    frame_width: int,
    frame_height: int,
    edge_margin: float,
) -> FramingDecision | None:
    """Choose the most objects that fit; break ties by least camera movement."""

    items = tuple(sorted(objects, key=lambda item: item.track_id))
    if not items:
        return None

    max_width = frame_width * (1.0 - 2.0 * edge_margin)
    max_height = frame_height * (1.0 - 2.0 * edge_margin)
    all_box = union_box(items)
    if box_fits(all_box, max_width, max_height):
        return make_decision(items, len(items))

    max_left = max(0.0, frame_width - max_width)
    max_top = max(0.0, frame_height - max_height)
    candidate_lefts = {0.0, max_left}
    candidate_tops = {0.0, max_top}
    for item in items:
        x1, y1, x2, y2 = item.box
        candidate_lefts.add(clamp(x1, 0.0, max_left))
        candidate_lefts.add(clamp(x2 - max_width, 0.0, max_left))
        candidate_tops.add(clamp(y1, 0.0, max_top))
        candidate_tops.add(clamp(y2 - max_height, 0.0, max_top))

    frame_center = (frame_width / 2.0, frame_height / 2.0)
    best_items: tuple[TrackedObject, ...] = ()
    best_score: tuple[int, float, float, tuple[int, ...]] | None = None
    epsilon = 1e-6

    for left in candidate_lefts:
        right = left + max_width
        for top in candidate_tops:
            bottom = top + max_height
            inside = tuple(
                item
                for item in items
                if item.box[0] >= left - epsilon
                and item.box[1] >= top - epsilon
                and item.box[2] <= right + epsilon
                and item.box[3] <= bottom + epsilon
            )
            if not inside:
                continue
            group_center = box_center(union_box(inside))
            normalized_distance = math.hypot(
                (group_center[0] - frame_center[0]) / max(frame_width, 1),
                (group_center[1] - frame_center[1]) / max(frame_height, 1),
            )
            score = (
                len(inside),
                -normalized_distance,
                sum(item.confidence for item in inside),
                tuple(-item.track_id for item in inside),
            )
            if best_score is None or score > best_score:
                best_score = score
                best_items = inside

    # A very large single box may not fit inside the reserved edge margins.
    # It is still a valid target, so select the closest such object as fallback.
    if not best_items:
        best_items = (
            min(
                items,
                key=lambda item: (
                    math.hypot(
                        (item.center[0] - frame_center[0]) / max(frame_width, 1),
                        (item.center[1] - frame_center[1]) / max(frame_height, 1),
                    ),
                    -item.confidence,
                    item.track_id,
                ),
            ),
        )

    return make_decision(best_items, len(items))


class StableGroupSelector:
    """Prevent equal-sized groups from causing rapid camera switching."""

    def __init__(self, switch_frames: int) -> None:
        self.switch_frames = switch_frames
        self.current_ids: frozenset[int] = frozenset()
        self.pending_ids: frozenset[int] = frozenset()
        self.pending_frames = 0

    def select(
        self,
        objects: Iterable[TrackedObject],
        frame_width: int,
        frame_height: int,
        edge_margin: float,
    ) -> FramingDecision | None:
        items = tuple(objects)
        candidate = choose_best_group(items, frame_width, frame_height, edge_margin)
        if candidate is None:
            self.current_ids = frozenset()
            self.pending_ids = frozenset()
            self.pending_frames = 0
            return None

        candidate_ids = frozenset(item.track_id for item in candidate.objects)
        current_objects = tuple(
            item for item in items if item.track_id in self.current_ids
        )

        if not current_objects:
            self.current_ids = candidate_ids
            self.pending_ids = frozenset()
            self.pending_frames = 0
            return candidate

        current_available_ids = frozenset(item.track_id for item in current_objects)
        if candidate_ids == current_available_ids:
            self.current_ids = candidate_ids
            self.pending_ids = frozenset()
            self.pending_frames = 0
            return candidate

        if candidate_ids == self.pending_ids:
            self.pending_frames += 1
        else:
            self.pending_ids = candidate_ids
            self.pending_frames = 1

        if self.pending_frames >= self.switch_frames:
            self.current_ids = candidate_ids
            self.pending_ids = frozenset()
            self.pending_frames = 0
            return candidate

        return make_decision(current_objects, len(items))


class AutoFrameController:
    def __init__(
        self,
        ema_alpha: float,
        deadzone_width: float,
        deadzone_height: float,
        home_after_seconds: float,
    ) -> None:
        self.ema_alpha = ema_alpha
        self.deadzone_width = deadzone_width
        self.deadzone_height = deadzone_height
        self.home_after_seconds = home_after_seconds
        self.smoothed_target: Point | None = None
        self.last_target_seen_at: float | None = None
        self.last_error_x = 0.0
        self.last_error_y = 0.0

    def update(
        self,
        decision: FramingDecision | None,
        frame_width: int,
        frame_height: int,
        now: float,
    ) -> CameraCommand:
        if decision is None:
            if (
                self.last_target_seen_at is not None
                and now - self.last_target_seen_at < self.home_after_seconds
            ):
                return CameraCommand(
                    state="NO_TARGET_HOLD",
                    direction="HOLD",
                    command_x="HOLD",
                    command_y="HOLD",
                    target_ids=(),
                    target_count=0,
                    total_stable_objects=0,
                    center_x=None,
                    center_y=None,
                    error_x=self.last_error_x,
                    error_y=self.last_error_y,
                    group_box=None,
                    limited_group=False,
                )

            self.smoothed_target = None
            self.last_error_x = 0.0
            self.last_error_y = 0.0
            return CameraCommand(
                state="RETURN_HOME",
                direction="HOME",
                command_x="HOME",
                command_y="HOME",
                target_ids=(),
                target_count=0,
                total_stable_objects=0,
                center_x=0.5,
                center_y=0.5,
                error_x=0.0,
                error_y=0.0,
                group_box=None,
                limited_group=False,
            )

        raw_x, raw_y = decision.raw_center
        if self.smoothed_target is None:
            smooth_x, smooth_y = raw_x, raw_y
        else:
            smooth_x = (
                self.ema_alpha * raw_x
                + (1.0 - self.ema_alpha) * self.smoothed_target[0]
            )
            smooth_y = (
                self.ema_alpha * raw_y
                + (1.0 - self.ema_alpha) * self.smoothed_target[1]
            )
        self.smoothed_target = (smooth_x, smooth_y)
        self.last_target_seen_at = now

        frame_center_x = frame_width / 2.0
        frame_center_y = frame_height / 2.0
        pixel_error_x = smooth_x - frame_center_x
        pixel_error_y = smooth_y - frame_center_y
        normalized_error_x = pixel_error_x / max(frame_center_x, 1.0)
        normalized_error_y = pixel_error_y / max(frame_center_y, 1.0)
        move_x = abs(pixel_error_x) > frame_width * self.deadzone_width / 2.0
        move_y = abs(pixel_error_y) > frame_height * self.deadzone_height / 2.0

        horizontal = ""
        vertical = ""
        if move_x:
            horizontal = "RIGHT" if pixel_error_x > 0 else "LEFT"
        if move_y:
            vertical = "DOWN" if pixel_error_y > 0 else "UP"
        direction = "_".join(part for part in (horizontal, vertical) if part) or "HOLD"
        command_x = horizontal or "HOLD"
        command_y = vertical or "HOLD"
        self.last_error_x = round(normalized_error_x, 6)
        self.last_error_y = round(normalized_error_y, 6)

        x1, y1, x2, y2 = decision.group_box
        return CameraCommand(
            state="TRACKING",
            direction=direction,
            command_x=command_x,
            command_y=command_y,
            target_ids=tuple(item.track_id for item in decision.objects),
            target_count=len(decision.objects),
            total_stable_objects=decision.total_stable_objects,
            center_x=round(smooth_x / max(frame_width, 1), 6),
            center_y=round(smooth_y / max(frame_height, 1), 6),
            error_x=self.last_error_x,
            error_y=self.last_error_y,
            group_box=(
                round(x1 / max(frame_width, 1), 6),
                round(y1 / max(frame_height, 1), 6),
                round(x2 / max(frame_width, 1), 6),
                round(y2 / max(frame_height, 1), 6),
            ),
            limited_group=decision.limited_group,
        )


def update_tracks(
    result: Any,
    frame_index: int,
    histories: dict[int, TrackLife],
    min_track_frames: int,
) -> tuple[TrackedObject, ...]:
    boxes = result.boxes
    if boxes is None or len(boxes) == 0 or boxes.id is None:
        stale_before = frame_index - 300
        for track_id in tuple(histories):
            if histories[track_id].last_frame < stale_before:
                del histories[track_id]
        return ()

    xyxy_values = boxes.xyxy.detach().cpu().tolist()
    confidence_values = boxes.conf.detach().cpu().tolist()
    class_values = boxes.cls.detach().cpu().tolist()
    id_values = boxes.id.detach().cpu().tolist()
    stable_objects: list[TrackedObject] = []

    for raw_box, confidence, class_id_value, track_id_value in zip(
        xyxy_values,
        confidence_values,
        class_values,
        id_values,
    ):
        track_id = int(track_id_value)
        class_id = int(class_id_value)
        previous = histories.get(track_id)
        consecutive = (
            previous.consecutive_frames + 1
            if previous is not None and previous.last_frame == frame_index - 1
            else 1
        )
        histories[track_id] = TrackLife(consecutive, frame_index)
        if consecutive < min_track_frames:
            continue

        stable_objects.append(
            TrackedObject(
                track_id=track_id,
                class_id=class_id,
                class_name=TARGET_CLASSES.get(class_id, str(class_id)),
                confidence=float(confidence),
                box=tuple(float(value) for value in raw_box),
            )
        )

    stale_before = frame_index - 300
    for track_id in tuple(histories):
        if histories[track_id].last_frame < stale_before:
            del histories[track_id]
    return tuple(stable_objects)


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


def create_network_capture(args: argparse.Namespace, source: str) -> Any:
    """Open one low-latency FFmpeg-backed capture for a network source."""

    if source.casefold().startswith(("rtsp://", "rtsps://")):
        os.environ.setdefault(
            "OPENCV_FFMPEG_CAPTURE_OPTIONS",
            "rtsp_transport;tcp",
        )

    parameters: list[int] = []
    if hasattr(cv2, "CAP_PROP_OPEN_TIMEOUT_MSEC"):
        parameters.extend(
            [
                cv2.CAP_PROP_OPEN_TIMEOUT_MSEC,
                max(1, round(args.stream_open_timeout_seconds * 1_000)),
            ]
        )
    if hasattr(cv2, "CAP_PROP_READ_TIMEOUT_MSEC"):
        parameters.extend(
            [
                cv2.CAP_PROP_READ_TIMEOUT_MSEC,
                max(1, round(args.stream_read_timeout_seconds * 1_000)),
            ]
        )

    try:
        if parameters:
            capture = cv2.VideoCapture(source, cv2.CAP_FFMPEG, parameters)
        else:
            capture = cv2.VideoCapture(source, cv2.CAP_FFMPEG)
    except (TypeError, cv2.error):
        capture = cv2.VideoCapture(source, cv2.CAP_FFMPEG)
    capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    return capture


def open_source(args: argparse.Namespace) -> tuple[Any, bool, str]:
    if args.video is not None:
        video_path = args.video.expanduser().resolve()
        if not video_path.is_file():
            raise SystemExit(f"Input video not found: {video_path}")
        capture = cv2.VideoCapture(str(video_path))
        if not capture.isOpened():
            raise SystemExit(f"Could not open input video: {video_path}")
        return capture, True, str(video_path)

    if args.stream_url:
        capture = LatestFrameCapture(
            args.stream_url,
            lambda source: create_network_capture(args, source),
            property_ids=(
                cv2.CAP_PROP_FRAME_WIDTH,
                cv2.CAP_PROP_FRAME_HEIGHT,
                cv2.CAP_PROP_FPS,
            ),
            reconnect_initial_seconds=args.reconnect_initial_seconds,
            reconnect_max_seconds=args.reconnect_max_seconds,
        )
        return capture, False, redact_stream_url(args.stream_url)

    capture = cv2.VideoCapture(args.camera, cv2.CAP_V4L2)
    if not capture.isOpened():
        capture.release()
        capture = cv2.VideoCapture(args.camera)
    if not capture.isOpened():
        raise SystemExit(
            f"Could not open /dev/video{args.camera}. Check the camera index and permissions."
        )
    capture.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
    capture.set(cv2.CAP_PROP_FPS, args.fps)
    capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    return capture, False, f"/dev/video{args.camera}"


def create_writer(output_path: Path, frame: Any, fps: float) -> Any:
    resolved_path = output_path.expanduser().resolve()
    resolved_path.parent.mkdir(parents=True, exist_ok=True)
    height, width = frame.shape[:2]
    writer = cv2.VideoWriter(
        str(resolved_path),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        (width, height),
    )
    if not writer.isOpened():
        raise SystemExit(f"Could not create output video: {resolved_path}")
    print(f"Annotated video: {resolved_path}")
    return writer


def open_control_output(path: Path | None) -> TextIO | None:
    if path is None:
        return None
    resolved_path = path.expanduser().resolve()
    resolved_path.parent.mkdir(parents=True, exist_ok=True)
    print(f"Control JSONL: {resolved_path}")
    return resolved_path.open("w", encoding="utf-8", buffering=1)


def draw_overlay(
    frame: Any,
    decision: FramingDecision | None,
    command: CameraCommand,
    controller: AutoFrameController,
    edge_margin: float,
    fps: float,
) -> Any:
    height, width = frame.shape[:2]
    center = (width // 2, height // 2)

    safe_left = int(width * edge_margin)
    safe_top = int(height * edge_margin)
    safe_right = int(width * (1.0 - edge_margin))
    safe_bottom = int(height * (1.0 - edge_margin))
    cv2.rectangle(
        frame,
        (safe_left, safe_top),
        (safe_right, safe_bottom),
        (110, 110, 110),
        1,
    )

    deadzone_half_width = int(width * controller.deadzone_width / 2.0)
    deadzone_half_height = int(height * controller.deadzone_height / 2.0)
    cv2.rectangle(
        frame,
        (center[0] - deadzone_half_width, center[1] - deadzone_half_height),
        (center[0] + deadzone_half_width, center[1] + deadzone_half_height),
        (255, 255, 0),
        2,
    )
    cv2.drawMarker(frame, center, (255, 255, 0), cv2.MARKER_CROSS, 18, 2)

    if decision is not None:
        for item in decision.objects:
            x1, y1, x2, y2 = (int(value) for value in item.box)
            cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 3)
            cv2.putText(
                frame,
                f"TARGET id={item.track_id} {item.class_name}",
                (x1, max(18, y1 - 8)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.52,
                (0, 255, 0),
                2,
                cv2.LINE_AA,
            )

        x1, y1, x2, y2 = (int(value) for value in decision.group_box)
        cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 215, 255), 3)
        raw_center = (int(decision.raw_center[0]), int(decision.raw_center[1]))
        cv2.drawMarker(frame, raw_center, (0, 215, 255), cv2.MARKER_CROSS, 20, 2)

    if controller.smoothed_target is not None and command.state == "TRACKING":
        smooth_center = (
            int(controller.smoothed_target[0]),
            int(controller.smoothed_target[1]),
        )
        cv2.line(frame, center, smooth_center, (0, 0, 255), 2)
        cv2.circle(frame, smooth_center, 7, (0, 0, 255), -1)

    mode = "LIMITED" if command.limited_group else "ALL"
    lines = (
        f"state={command.state}  command={command.direction}",
        (
            f"selected={command.target_count}/{command.total_stable_objects} "
            f"mode={mode} ids={list(command.target_ids)}"
        ),
        f"error=({command.error_x:+.3f}, {command.error_y:+.3f}) fps={fps:.1f}",
    )
    for index, line in enumerate(lines):
        y = 26 + index * 25
        cv2.putText(
            frame,
            line,
            (10, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.58,
            (0, 0, 0),
            4,
            cv2.LINE_AA,
        )
        cv2.putText(
            frame,
            line,
            (10, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.58,
            (255, 255, 255),
            1,
            cv2.LINE_AA,
        )
    return frame


def trigger_epoch(payload: dict[str, Any]) -> float:
    value = str(payload["occurredAt"])
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def write_event_video(
    event_dir: Path,
    event_id: str,
    frames: list[tuple[float, Any]],
    fps: float,
) -> None:
    if not frames:
        print(f"Event video skipped (no frames): {event_id}")
        return
    event_dir.mkdir(parents=True, exist_ok=True)
    destination = event_dir / f"{event_id}.video.mp4"
    temporary = event_dir / f"{event_id}.video.tmp.mp4"
    height, width = frames[0][1].shape[:2]
    elapsed = frames[-1][0] - frames[0][0] if len(frames) > 1 else 0.0
    output_fps = min(fps, (len(frames) - 1) / elapsed) if elapsed > 0 else fps
    output_fps = max(1.0, output_fps)
    writer = cv2.VideoWriter(
        str(temporary),
        cv2.VideoWriter_fourcc(*"mp4v"),
        output_fps,
        (width, height),
    )
    if not writer.isOpened():
        raise RuntimeError(f"Could not create event video: {temporary}")
    try:
        for _, frame in frames:
            writer.write(frame)
    finally:
        writer.release()
    temporary.replace(destination)
    print(f"Saved laughter video clip: {destination.name}")


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
    capture, is_video_file, source_name = open_source(args)
    writer = None
    control_output = open_control_output(args.control_output)
    vision_publisher = None
    if args.mqtt_host:
        from vision_mqtt_publisher import VisionMqttPublisher

        vision_publisher = VisionMqttPublisher(
            host=args.mqtt_host,
            port=args.mqtt_port,
            device_id=args.device_id,
            username=args.mqtt_username,
            password=args.mqtt_password,
            topic=args.mqtt_topic,
            control_topic=args.control_mqtt_topic,
        )
    histories: dict[int, TrackLife] = {}
    selector = StableGroupSelector(args.switch_frames)
    controller = AutoFrameController(
        ema_alpha=args.ema_alpha,
        deadzone_width=args.deadzone_width,
        deadzone_height=args.deadzone_height,
        home_after_seconds=args.home_after_seconds,
    )

    frame_count = 0
    started_at = time.monotonic()
    last_report_at = started_at
    last_command_at = float("-inf")
    actual_fps = float(args.fps)
    source_details_printed = False
    frame_history: deque[tuple[float, Any]] = deque()
    pending_video_clips: dict[str, dict[str, Any]] = {}
    seen_event_ids: set[str] = set()
    last_trigger_scan_at = float("-inf")

    print(f"Model: {model_path}")
    print(f"Device: {device}")
    if device != "cpu":
        print(f"CUDA device: {torch.cuda.get_device_name(int(device))}")
    print("Tracker: ByteTrack; classes: person, cat, dog")
    print("Motor output is disabled. This run only simulates framing commands.")
    print("Press Ctrl+C to stop" + (", or q in the display window." if args.display else "."))

    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                if is_video_file:
                    print("Input video ended.")
                    break
                raise SystemExit("The camera opened, but a frame could not be read.")

            if not source_details_printed:
                actual_height, actual_width = frame.shape[:2]
                reported_fps = capture.get(cv2.CAP_PROP_FPS)
                if reported_fps > 0:
                    actual_fps = reported_fps
                print(
                    f"Source: {source_name} "
                    f"({actual_width}x{actual_height} @ {actual_fps:.1f} FPS)"
                )
                source_details_printed = True

            frame_epoch = time.time()
            if args.event_dir is not None:
                frame_history.append((frame_epoch, frame.copy()))
                history_cutoff = frame_epoch - args.clip_seconds - 1.0
                while frame_history and frame_history[0][0] < history_cutoff:
                    frame_history.popleft()

                for pending in pending_video_clips.values():
                    if frame_epoch > pending["last_frame_at"]:
                        pending["frames"].append((frame_epoch, frame.copy()))
                        pending["last_frame_at"] = frame_epoch

                if frame_epoch - last_trigger_scan_at >= 0.25:
                    args.event_dir.mkdir(parents=True, exist_ok=True)
                    for trigger_path in args.event_dir.glob("*.trigger.json"):
                        event_id = trigger_path.name.removesuffix(".trigger.json")
                        if event_id in seen_event_ids:
                            continue
                        try:
                            payload = json.loads(trigger_path.read_text(encoding="utf-8"))
                            occurred_at = trigger_epoch(payload)
                        except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
                            print(f"Invalid local event trigger {trigger_path.name}: {error}")
                            seen_event_ids.add(event_id)
                            continue
                        clip_seconds = float(payload.get("postSeconds", args.clip_seconds))
                        pre_seconds = float(payload.get("preSeconds", args.clip_seconds))
                        selected = [
                            item
                            for item in frame_history
                            if occurred_at - pre_seconds <= item[0] <= frame_epoch
                        ]
                        pending_video_clips[event_id] = {
                            "frames": selected,
                            "last_frame_at": selected[-1][0] if selected else float("-inf"),
                            "deadline": occurred_at + clip_seconds,
                        }
                        seen_event_ids.add(event_id)
                        print(f"Capturing laughter video event: {event_id}")
                    last_trigger_scan_at = frame_epoch

                for event_id, pending in tuple(pending_video_clips.items()):
                    if frame_epoch >= pending["deadline"]:
                        write_event_video(
                            args.event_dir,
                            event_id,
                            pending["frames"],
                            actual_fps,
                        )
                        del pending_video_clips[event_id]

            frame_count += 1
            track_options: dict[str, Any] = {
                "source": frame,
                "persist": True,
                "tracker": args.tracker,
                "device": device,
                "classes": TARGET_CLASS_IDS,
                "conf": args.confidence,
                "imgsz": args.imgsz,
                "verbose": False,
            }
            if args.half and device != "cpu" and model_path.suffix == ".pt":
                track_options["half"] = True
            results = model.track(**track_options)
            result = results[0]
            stable_objects = update_tracks(
                result,
                frame_count,
                histories,
                args.min_track_frames,
            )
            height, width = frame.shape[:2]
            decision = selector.select(
                stable_objects,
                width,
                height,
                args.edge_margin,
            )
            wall_now = time.monotonic()
            timeline_now = (
                capture.get(cv2.CAP_PROP_POS_MSEC) / 1000.0
                if is_video_file
                else wall_now
            )
            command = controller.update(decision, width, height, timeline_now)
            average_fps = frame_count / max(wall_now - started_at, 1e-6)

            annotated_frame = result.plot()
            annotated_frame = draw_overlay(
                annotated_frame,
                decision,
                command,
                controller,
                args.edge_margin,
                average_fps,
            )

            if (
                (control_output is not None or vision_publisher is not None)
                and timeline_now - last_command_at >= args.command_interval
            ):
                command_payload = command.as_payload(frame_count)
                command_payload["device_id"] = args.device_id
                command_payload["object_counts"] = {
                    class_name: sum(
                        item.class_name == class_name for item in stable_objects
                    )
                    for class_name in TARGET_CLASSES.values()
                }
                command_payload["track_ids"] = [
                    item.track_id for item in stable_objects
                ]
                if control_output is not None:
                    control_output.write(
                        json.dumps(
                            command_payload,
                            ensure_ascii=False,
                            separators=(",", ":"),
                        )
                        + "\n"
                    )
                if vision_publisher is not None:
                    vision_publisher.publish_state(command_payload)
                last_command_at = timeline_now

            if args.output is not None:
                if writer is None:
                    writer = create_writer(args.output, annotated_frame, actual_fps)
                writer.write(annotated_frame)

            if wall_now - last_report_at >= 1.0:
                print(
                    f"frames={frame_count} fps={average_fps:.1f} "
                    f"state={command.state} command={command.direction} "
                    f"targets={command.target_count}/{command.total_stable_objects} "
                    f"ids={list(command.target_ids)} "
                    f"error=({command.error_x:+.3f},{command.error_y:+.3f})"
                )
                last_report_at = wall_now

            if args.display:
                cv2.imshow("YOLOv8 Jetson Auto Framing", annotated_frame)
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
        if control_output is not None:
            control_output.close()
        if vision_publisher is not None:
            vision_publisher.close()
        cv2.destroyAllWindows()

    elapsed = max(time.monotonic() - started_at, 1e-6)
    print(f"Finished: {frame_count} frames, average {frame_count / elapsed:.1f} FPS")


def main() -> None:
    run(parse_args())


if __name__ == "__main__":
    main()
