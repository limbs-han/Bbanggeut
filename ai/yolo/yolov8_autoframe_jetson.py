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
import statistics
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
    # False once the head cluster no longer fits: revealing one head would
    # drop another, so the axis holds instead of oscillating between them.
    heads_fit: bool = True

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
        "--subject-y-ratio",
        type=float,
        default=0.05,
        help=(
            "Vertical tracking point inside the selected subject box: "
            "0 is top, 0.5 is center, 1 is bottom (default: 0.05)."
        ),
    )
    parser.add_argument(
        "--head-ratio",
        type=float,
        default=float(os.getenv("YOLO_HEAD_RATIO", "0.28")),
        help=(
            "Top fraction of each subject box treated as head and shoulders "
            "for safe-frame edge checks (default: 0.28)."
        ),
    )
    parser.add_argument(
        "--tracking-mode",
        choices=("center", "safe-frame", "heads"),
        default=os.getenv("YOLO_TRACKING_MODE", "center"),
        help=(
            "center tracks a point, safe-frame moves only near an edge, "
            "heads keeps every head in frame and then holds their median."
        ),
    )
    parser.add_argument(
        "--head-anchor-ratio",
        type=float,
        default=float(os.getenv("YOLO_HEAD_ANCHOR_RATIO", "0.33")),
        help=(
            "Where the head median should sit vertically once every head "
            "has clearance, as a frame ratio (default: 0.33)."
        ),
    )
    parser.add_argument(
        "--head-clearance",
        type=float,
        default=float(os.getenv("YOLO_HEAD_CLEARANCE", "0.06")),
        help="Margin every head must keep from a frame edge (default: 0.06).",
    )
    parser.add_argument(
        "--head-memory-seconds",
        type=float,
        default=float(os.getenv("YOLO_HEAD_MEMORY_SECONDS", "0.8")),
        help=(
            "How long a head that stops being detected still counts toward "
            "the framing, so a blink does not move the aim (default: 0.8)."
        ),
    )
    parser.add_argument(
        "--head-settle-ratio",
        type=float,
        default=float(os.getenv("YOLO_HEAD_SETTLE_RATIO", "1.0")),
        help=(
            "Fraction of the dead-zone a started move closes to before it "
            "stops. Below 1 the camera travels further per correction, which "
            "measurably worsens overshoot once loop latency is significant, "
            "so it stays at 1 unless latency is known to be small."
        ),
    )
    parser.add_argument(
        "--head-clearance-stop",
        type=float,
        default=float(os.getenv("YOLO_HEAD_CLEARANCE_STOP", "0.10")),
        help=(
            "Margin a correcting axis restores before it stops, which keeps "
            "it from retriggering at once (default: 0.10)."
        ),
    )
    parser.add_argument(
        "--safe-frame-start-margin",
        type=float,
        default=float(os.getenv("YOLO_SAFE_FRAME_START_MARGIN", "0.08")),
        help="Edge margin that starts safe-frame movement (default: 0.08).",
    )
    parser.add_argument(
        "--safe-frame-stop-margin",
        type=float,
        default=float(os.getenv("YOLO_SAFE_FRAME_STOP_MARGIN", "0.12")),
        help="Inner margin that stops safe-frame movement (default: 0.12).",
    )
    parser.add_argument(
        "--safe-frame-edge-guard",
        type=float,
        default=float(os.getenv("YOLO_SAFE_FRAME_EDGE_GUARD", "0.04")),
        help="Person-box edge guard used to prevent target loss (default: 0.04).",
    )
    parser.add_argument(
        "--target-loss-follow-seconds",
        type=float,
        default=float(os.getenv("YOLO_TARGET_LOSS_FOLLOW_SECONDS", "0.5")),
        help="Briefly continue an edge-exit command after target loss.",
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
        "--dashboard-host",
        default=os.getenv("SERVO_DASHBOARD_HOST", "127.0.0.1"),
        help="Servo dashboard bind address (default: 127.0.0.1).",
    )
    parser.add_argument(
        "--dashboard-port",
        type=int,
        default=int(os.getenv("SERVO_DASHBOARD_PORT", "0")),
        help="Servo dashboard HTTP port. Set 0 to disable (default: 0).",
    )
    parser.add_argument(
        "--dashboard-log",
        type=Path,
        help="Optional JSON Lines path for vision, servo, and laughter logs.",
    )
    parser.add_argument(
        "--dashboard-event-dir",
        type=Path,
        help="Watch laughter trigger and upload markers without capturing clips.",
    )
    parser.add_argument(
        "--dashboard-yamnet-diagnostics",
        type=Path,
        help="Tail YAMNet inference JSONL for live score and RMS telemetry.",
    )
    parser.add_argument(
        "--dashboard-frame-width",
        type=int,
        default=int(os.getenv("SERVO_DASHBOARD_FRAME_WIDTH", "960")),
        help="Maximum dashboard JPEG width (default: 960).",
    )
    parser.add_argument(
        "--dashboard-jpeg-quality",
        type=int,
        default=int(os.getenv("SERVO_DASHBOARD_JPEG_QUALITY", "72")),
        help="Dashboard JPEG quality from 30 through 95 (default: 72).",
    )
    parser.add_argument(
        "--dashboard-frame-interval",
        type=float,
        default=float(os.getenv("SERVO_DASHBOARD_FRAME_INTERVAL_SECONDS", "0.2")),
        help="Minimum seconds between dashboard frames (default: 0.2).",
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
    if not 0.0 <= args.subject_y_ratio <= 1.0:
        parser.error("--subject-y-ratio must be between 0 and 1")
    if not 0.0 < args.head_ratio <= 1.0:
        parser.error("--head-ratio must be greater than 0 and at most 1")
    if not 0.0 < args.head_anchor_ratio < 1.0:
        parser.error("--head-anchor-ratio must be between 0 and 1")
    if not 0.0 <= args.head_clearance < args.head_clearance_stop < 0.45:
        parser.error(
            "--head-clearance must be at least 0 and less than "
            "--head-clearance-stop, which must be less than 0.45"
        )
    if not 0.0 < args.head_settle_ratio <= 1.0:
        parser.error("--head-settle-ratio must be greater than 0 and at most 1")
    if args.head_memory_seconds < 0.0:
        parser.error("--head-memory-seconds cannot be negative")
    if not 0.0 <= args.safe_frame_start_margin < 0.45:
        parser.error(
            "--safe-frame-start-margin must be at least 0 and less than 0.45"
        )
    if not args.safe_frame_start_margin < args.safe_frame_stop_margin < 0.45:
        parser.error(
            "--safe-frame-stop-margin must be greater than the start margin "
            "and less than 0.45"
        )
    if not 0.0 <= args.safe_frame_edge_guard < args.safe_frame_start_margin:
        parser.error(
            "--safe-frame-edge-guard must be at least 0 and less than "
            "--safe-frame-start-margin"
        )
    invalid_loss_follow = args.target_loss_follow_seconds < 0.0 or (
        args.home_after_seconds == 0.0
        and args.target_loss_follow_seconds != 0.0
    ) or (
        args.home_after_seconds > 0.0
        and args.target_loss_follow_seconds >= args.home_after_seconds
    )
    if invalid_loss_follow:
        parser.error(
            "--target-loss-follow-seconds must be at least 0 and less than "
            "--home-after-seconds"
        )
    if not 0.0 < args.ema_alpha <= 1.0:
        parser.error("--ema-alpha must be greater than 0 and at most 1")
    if args.home_after_seconds < 0:
        parser.error("--home-after-seconds cannot be negative")
    if args.command_interval <= 0:
        parser.error("--command-interval must be positive")
    if not 1 <= args.mqtt_port <= 65_535:
        parser.error("--mqtt-port must be between 1 and 65535")
    if not 0 <= args.dashboard_port <= 65_535:
        parser.error("--dashboard-port must be between 0 and 65535")
    if args.dashboard_port and not args.mqtt_host:
        parser.error("--dashboard-port requires --mqtt-host")
    if args.dashboard_frame_width < 160:
        parser.error("--dashboard-frame-width must be at least 160")
    if not 30 <= args.dashboard_jpeg_quality <= 95:
        parser.error("--dashboard-jpeg-quality must be between 30 and 95")
    if args.dashboard_frame_interval <= 0:
        parser.error("--dashboard-frame-interval must be positive")
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
        include_all: bool = False,
    ) -> FramingDecision | None:
        items = tuple(objects)
        candidate = (
            make_decision(items, len(items))
            if include_all and items
            else choose_best_group(items, frame_width, frame_height, edge_margin)
        )
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
        subject_y_ratio: float,
        home_after_seconds: float,
        tracking_mode: str = "center",
        safe_frame_start_margin: float = 0.08,
        safe_frame_stop_margin: float = 0.12,
        safe_frame_edge_guard: float = 0.04,
        target_loss_follow_seconds: float = 0.5,
        head_ratio: float = 0.28,
        head_anchor_ratio: float = 0.33,
        head_clearance: float = 0.06,
        head_clearance_stop: float = 0.10,
        head_settle_ratio: float = 1.0,
        head_memory_seconds: float = 0.8,
    ) -> None:
        if not 0.0 <= subject_y_ratio <= 1.0:
            raise ValueError("subject_y_ratio must be between 0 and 1")
        if not 0.0 < head_ratio <= 1.0:
            raise ValueError("head_ratio must be greater than 0 and at most 1")
        if tracking_mode not in {"center", "safe-frame", "heads"}:
            raise ValueError("tracking_mode must be center, safe-frame or heads")
        if not 0.0 < head_anchor_ratio < 1.0:
            raise ValueError("head_anchor_ratio must be between 0 and 1")
        if not 0.0 <= head_clearance < head_clearance_stop < 0.45:
            raise ValueError(
                "head clearances must satisfy 0 <= clearance < stop < 0.45"
            )
        if not 0.0 < head_settle_ratio <= 1.0:
            raise ValueError(
                "head_settle_ratio must be greater than 0 and at most 1"
            )
        if head_memory_seconds < 0.0:
            raise ValueError("head_memory_seconds cannot be negative")
        if not 0.0 <= safe_frame_start_margin < safe_frame_stop_margin < 0.45:
            raise ValueError(
                "safe-frame margins must satisfy 0 <= start < stop < 0.45"
            )
        if not 0.0 <= safe_frame_edge_guard < safe_frame_start_margin:
            raise ValueError(
                "safe_frame_edge_guard must be at least 0 and less than "
                "safe_frame_start_margin"
            )
        invalid_loss_follow = target_loss_follow_seconds < 0.0 or (
            home_after_seconds == 0.0 and target_loss_follow_seconds != 0.0
        ) or (
            home_after_seconds > 0.0
            and target_loss_follow_seconds >= home_after_seconds
        )
        if invalid_loss_follow:
            raise ValueError(
                "target_loss_follow_seconds must be at least 0 and less than "
                "home_after_seconds"
            )
        self.ema_alpha = ema_alpha
        self.deadzone_width = deadzone_width
        self.deadzone_height = deadzone_height
        self.subject_y_ratio = subject_y_ratio
        self.home_after_seconds = home_after_seconds
        self.tracking_mode = tracking_mode
        self.safe_frame_start_margin = safe_frame_start_margin
        self.safe_frame_stop_margin = safe_frame_stop_margin
        self.safe_frame_edge_guard = safe_frame_edge_guard
        self.target_loss_follow_seconds = target_loss_follow_seconds
        self.head_ratio = head_ratio
        self.head_anchor_ratio = head_anchor_ratio
        self.head_clearance = head_clearance
        self.head_clearance_stop = head_clearance_stop
        self.head_settle_ratio = head_settle_ratio
        self.head_memory_seconds = head_memory_seconds
        self.remembered_heads: dict[int, tuple[Box, float]] = {}
        self.smoothed_head_median: Point | None = None
        self.head_median_x_active = False
        self.head_median_y_active = False
        self.heads_fit = True
        self.smoothed_target: Point | None = None
        self.smoothed_group_box: Box | None = None
        self.smoothed_tracking_points_box: Box | None = None
        self.last_target_seen_at: float | None = None
        self.last_error_x = 0.0
        self.last_error_y = 0.0
        self.safe_frame_x_active = False
        self.safe_frame_y_active = False
        self.loss_command_x = "HOLD"
        self.loss_command_y = "HOLD"

    def _safe_point_axis(
        self,
        point_low: float,
        point_high: float,
        low: float,
        high: float,
        frame_size: int,
        active: bool,
    ) -> tuple[int, float, bool]:
        point_margin = (
            self.safe_frame_stop_margin
            if active
            else self.safe_frame_start_margin
        )
        guard_margin = self.safe_frame_edge_guard
        if active:
            guard_margin += (
                self.safe_frame_stop_margin - self.safe_frame_start_margin
            )

        point_lower_error = point_low - frame_size * point_margin
        point_upper_error = point_high - frame_size * (1.0 - point_margin)
        box_lower_error = low - frame_size * guard_margin
        box_upper_error = high - frame_size * (1.0 - guard_margin)
        lower_error = min(point_lower_error, box_lower_error)
        upper_error = max(point_upper_error, box_upper_error)
        lower_outside = lower_error < 0.0
        upper_outside = upper_error > 0.0

        if lower_outside and upper_outside:
            point_below = point_lower_error < 0.0
            point_above = point_upper_error > 0.0
            if point_below and not point_above:
                upper_outside = False
            elif point_above and not point_below:
                lower_outside = False
            else:
                return 0, 0.0, False
        if not lower_outside and not upper_outside:
            return 0, 0.0, False
        normalizer = max(frame_size / 2.0, 1.0)
        if lower_outside:
            return -1, clamp(lower_error / normalizer, -1.0, 1.0), True
        return 1, clamp(upper_error / normalizer, -1.0, 1.0), True

    def head_box(self, item: TrackedObject) -> Box:
        """Keep only the top slice of a detection, where the head sits.

        The detector has no face class, so this is a proportion of the whole
        body box rather than a measurement. It matters because safe-frame
        judges the framing box against both frame edges: a full body box on a
        nearby subject touches top and bottom at once, which reads as "cannot
        be framed either way" and stops all vertical motion. The head slice
        never reaches the bottom edge, so the axis keeps a usable direction.
        """

        x1, y1, x2, y2 = item.box
        return (x1, y1, x2, y1 + (y2 - y1) * self.head_ratio)

    def framing_box(self, decision: FramingDecision) -> Box:
        boxes = tuple(self.head_box(item) for item in decision.objects)
        return (
            min(box[0] for box in boxes),
            min(box[1] for box in boxes),
            max(box[2] for box in boxes),
            max(box[3] for box in boxes),
        )

    def remember_heads(
        self,
        decision: FramingDecision,
        now: float,
    ) -> tuple[Box, ...]:
        """Head boxes including ones that blinked out a moment ago.

        A detection that drops for a frame or two would otherwise remove a
        head from the median and move the aim somewhere else entirely, which
        reads as the camera lurching for no reason. Holding the last known
        position briefly keeps the aim on what the people are doing rather
        than on what the detector happened to catch this frame.
        """

        live_boxes: list[Box] = []
        for item in decision.objects:
            box = self.head_box(item)
            self.remembered_heads[item.track_id] = (box, now)
            live_boxes.append(box)

        live_ids = {item.track_id for item in decision.objects}
        coasting: list[Box] = []
        for track_id, (box, seen_at) in tuple(self.remembered_heads.items()):
            if track_id in live_ids:
                continue
            if now - seen_at > self.head_memory_seconds:
                del self.remembered_heads[track_id]
                continue
            # The tracker hands the same person a new id often enough that a
            # remembered head is usually their own stale copy rather than
            # someone who left. Keeping both would put the aim between a
            # person and their ghost, so an overlap is treated as a re-id.
            if any(self._same_head(box, live) for live in live_boxes):
                del self.remembered_heads[track_id]
                continue
            coasting.append(box)
        return tuple(live_boxes) + tuple(coasting)

    @staticmethod
    def _same_head(remembered: Box, live: Box) -> bool:
        width = min(remembered[2], live[2]) - max(remembered[0], live[0])
        height = min(remembered[3], live[3]) - max(remembered[1], live[1])
        if width <= 0.0 or height <= 0.0:
            return False
        overlap = width * height
        smaller = min(
            (remembered[2] - remembered[0]) * (remembered[3] - remembered[1]),
            (live[2] - live[0]) * (live[3] - live[1]),
        )
        return smaller > 0.0 and overlap / smaller >= 0.3

    def head_median(self, boxes: tuple[Box, ...]) -> Point:
        """The middle of where the heads are.

        A median rather than a mean: with three or more subjects one person
        leaning out should not drag the whole framing with them.
        """

        return (
            statistics.median((box[0] + box[2]) / 2.0 for box in boxes),
            statistics.median((box[1] + box[3]) / 2.0 for box in boxes),
        )

    @staticmethod
    def union_of(boxes: tuple[Box, ...]) -> Box:
        return (
            min(box[0] for box in boxes),
            min(box[1] for box in boxes),
            max(box[2] for box in boxes),
            max(box[3] for box in boxes),
        )

    def _head_axis(
        self,
        low: float,
        high: float,
        median: float,
        target: float,
        deadzone: float,
        frame_size: int,
        clearance_active: bool,
        median_active: bool,
    ) -> tuple[int, float, bool, bool, bool]:
        """Keep every head inside the frame first, then settle on the median.

        Returns direction, normalized error, whether the axis is correcting
        clearance, whether it is closing on the median, and whether the heads
        can fit at all.
        """

        clearance = (
            self.head_clearance_stop if clearance_active else self.head_clearance
        )
        lower_gap = low - frame_size * clearance
        upper_gap = high - frame_size * (1.0 - clearance)
        normalizer = max(frame_size / 2.0, 1.0)

        if lower_gap < 0.0 and upper_gap > 0.0:
            return 0, 0.0, False, False, False
        if lower_gap < 0.0:
            return -1, clamp(lower_gap / normalizer, -1.0, 1.0), True, False, True
        if upper_gap > 0.0:
            return 1, clamp(upper_gap / normalizer, -1.0, 1.0), True, False, True

        # Every head has clearance. Hold the framing until the median drifts
        # out of its box, so ordinary movement does not chase the camera.
        #
        # Starting and stopping on the same threshold would park the camera
        # exactly on it, where detection noise alone retriggers the move. A
        # move therefore continues until the median is well inside the box.
        offset = median - target
        threshold = deadzone / 2.0
        if median_active:
            threshold *= self.head_settle_ratio
        if abs(offset) <= threshold:
            return 0, 0.0, False, False, True
        direction = 1 if offset > 0.0 else -1

        # Clearance is a constraint and the median is only the objective. A
        # pull that would eat into the clearance just restored is what turns a
        # correction into a limit cycle, so it is refused instead.
        stop = self.head_clearance_stop
        if direction == 1 and low - frame_size * stop <= 0.0:
            return 0, 0.0, False, False, True
        if direction == -1 and high - frame_size * (1.0 - stop) >= 0.0:
            return 0, 0.0, False, False, True
        return direction, clamp(offset / normalizer, -1.0, 1.0), False, True, True

    def tracking_points(self, decision: FramingDecision) -> tuple[Point, ...]:
        return tuple(
            (
                item.center[0],
                item.box[1]
                + (item.box[3] - item.box[1]) * self.subject_y_ratio,
            )
            for item in decision.objects
        )

    def tracking_points_box(self, decision: FramingDecision) -> Box:
        points = self.tracking_points(decision)
        return (
            min(point[0] for point in points),
            min(point[1] for point in points),
            max(point[0] for point in points),
            max(point[1] for point in points),
        )

    def _edge_exit_command(
        self,
        low: float,
        high: float,
        frame_size: int,
        negative_command: str,
        positive_command: str,
    ) -> str:
        boundary = frame_size * self.safe_frame_edge_guard
        near_lower = low < boundary
        near_upper = high > frame_size - boundary
        if near_lower == near_upper:
            return "HOLD"
        return negative_command if near_lower else positive_command

    def update(
        self,
        decision: FramingDecision | None,
        frame_width: int,
        frame_height: int,
        now: float,
    ) -> CameraCommand:
        if decision is None:
            self.safe_frame_x_active = False
            self.safe_frame_y_active = False
            elapsed = (
                now - self.last_target_seen_at
                if self.last_target_seen_at is not None
                else float("inf")
            )
            if elapsed < self.target_loss_follow_seconds and (
                self.loss_command_x != "HOLD" or self.loss_command_y != "HOLD"
            ):
                direction = "_".join(
                    command
                    for command in (self.loss_command_x, self.loss_command_y)
                    if command != "HOLD"
                )
                return CameraCommand(
                    state="TARGET_LOSS_FOLLOW",
                    direction=direction,
                    command_x=self.loss_command_x,
                    command_y=self.loss_command_y,
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
            self.loss_command_x = "HOLD"
            self.loss_command_y = "HOLD"
            if (
                self.last_target_seen_at is not None
                and elapsed < self.home_after_seconds
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
            self.smoothed_group_box = None
            self.smoothed_tracking_points_box = None
            self.smoothed_head_median = None
            self.remembered_heads.clear()
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

        raw_x, _ = decision.raw_center
        _, subject_top, _, subject_bottom = decision.group_box
        raw_y = subject_top + (
            subject_bottom - subject_top
        ) * self.subject_y_ratio
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

        # Safe-frame and heads judge edges against the head slice; center mode
        # still frames the whole body.
        if self.tracking_mode == "heads":
            live_heads = self.remember_heads(decision, now)
            raw_framing_box = self.union_of(live_heads)
        elif self.tracking_mode == "safe-frame":
            live_heads = ()
            raw_framing_box = self.framing_box(decision)
        else:
            live_heads = ()
            raw_framing_box = decision.group_box
        if self.smoothed_group_box is None:
            self.smoothed_group_box = raw_framing_box
        else:
            self.smoothed_group_box = tuple(
                self.ema_alpha * raw_value
                + (1.0 - self.ema_alpha) * smooth_value
                for raw_value, smooth_value in zip(
                    raw_framing_box,
                    self.smoothed_group_box,
                )
            )

        tracking_points_box = self.tracking_points_box(decision)
        if self.smoothed_tracking_points_box is None:
            self.smoothed_tracking_points_box = tracking_points_box
        else:
            self.smoothed_tracking_points_box = tuple(
                self.ema_alpha * raw_value
                + (1.0 - self.ema_alpha) * smooth_value
                for raw_value, smooth_value in zip(
                    tracking_points_box,
                    self.smoothed_tracking_points_box,
                )
            )

        if self.tracking_mode == "heads":
            raw_median = self.head_median(live_heads)
            if self.smoothed_head_median is None:
                self.smoothed_head_median = raw_median
            else:
                self.smoothed_head_median = (
                    self.ema_alpha * raw_median[0]
                    + (1.0 - self.ema_alpha) * self.smoothed_head_median[0],
                    self.ema_alpha * raw_median[1]
                    + (1.0 - self.ema_alpha) * self.smoothed_head_median[1],
                )
            cluster_left, cluster_top, cluster_right, cluster_bottom = (
                self.smoothed_group_box
            )
            median_x, median_y = self.smoothed_head_median
            (
                x_direction,
                normalized_error_x,
                self.safe_frame_x_active,
                self.head_median_x_active,
                x_fits,
            ) = self._head_axis(
                cluster_left,
                cluster_right,
                median_x,
                frame_width / 2.0,
                frame_width * self.deadzone_width,
                frame_width,
                self.safe_frame_x_active,
                self.head_median_x_active,
            )
            (
                y_direction,
                normalized_error_y,
                self.safe_frame_y_active,
                self.head_median_y_active,
                y_fits,
            ) = self._head_axis(
                cluster_top,
                cluster_bottom,
                median_y,
                frame_height * self.head_anchor_ratio,
                frame_height * self.deadzone_height,
                frame_height,
                self.safe_frame_y_active,
                self.head_median_y_active,
            )
            self.heads_fit = x_fits and y_fits
            horizontal = {-1: "LEFT", 0: "", 1: "RIGHT"}[x_direction]
            vertical = {-1: "UP", 0: "", 1: "DOWN"}[y_direction]
            self.loss_command_x = self._edge_exit_command(
                cluster_left,
                cluster_right,
                frame_width,
                "LEFT",
                "RIGHT",
            )
            self.loss_command_y = self._edge_exit_command(
                cluster_top,
                cluster_bottom,
                frame_height,
                "UP",
                "DOWN",
            )
        elif self.tracking_mode == "safe-frame":
            smooth_left, smooth_top, smooth_right, smooth_bottom = (
                self.smoothed_group_box
            )
            point_left, point_top, point_right, point_bottom = (
                self.smoothed_tracking_points_box
            )
            x_direction, normalized_error_x, self.safe_frame_x_active = (
                self._safe_point_axis(
                    point_left,
                    point_right,
                    smooth_left,
                    smooth_right,
                    frame_width,
                    self.safe_frame_x_active,
                )
            )
            y_direction, normalized_error_y, self.safe_frame_y_active = (
                self._safe_point_axis(
                    point_top,
                    point_bottom,
                    smooth_top,
                    smooth_bottom,
                    frame_height,
                    self.safe_frame_y_active,
                )
            )
            horizontal = {-1: "LEFT", 0: "", 1: "RIGHT"}[x_direction]
            vertical = {-1: "UP", 0: "", 1: "DOWN"}[y_direction]
            self.loss_command_x = self._edge_exit_command(
                smooth_left,
                smooth_right,
                frame_width,
                "LEFT",
                "RIGHT",
            )
            self.loss_command_y = self._edge_exit_command(
                smooth_top,
                smooth_bottom,
                frame_height,
                "UP",
                "DOWN",
            )
        else:
            self.loss_command_x = "HOLD"
            self.loss_command_y = "HOLD"
            frame_center_x = frame_width / 2.0
            frame_center_y = frame_height / 2.0
            pixel_error_x = smooth_x - frame_center_x
            pixel_error_y = smooth_y - frame_center_y
            normalized_error_x = pixel_error_x / max(frame_center_x, 1.0)
            normalized_error_y = pixel_error_y / max(frame_center_y, 1.0)
            move_x = abs(pixel_error_x) > frame_width * self.deadzone_width / 2.0
            move_y = abs(pixel_error_y) > frame_height * self.deadzone_height / 2.0
            horizontal = "RIGHT" if move_x and pixel_error_x > 0 else ""
            if move_x and pixel_error_x < 0:
                horizontal = "LEFT"
            vertical = "DOWN" if move_y and pixel_error_y > 0 else ""
            if move_y and pixel_error_y < 0:
                vertical = "UP"

        direction = "_".join(part for part in (horizontal, vertical) if part) or "HOLD"
        command_x = horizontal or "HOLD"
        command_y = vertical or "HOLD"
        self.last_error_x = round(normalized_error_x, 6)
        self.last_error_y = round(normalized_error_y, 6)

        # In heads mode the reported box and centre describe what is actually
        # being framed: the head cluster and its median.
        if self.tracking_mode == "heads":
            x1, y1, x2, y2 = self.smoothed_group_box
            smooth_x, smooth_y = self.smoothed_head_median
        else:
            x1, y1, x2, y2 = decision.group_box
        return CameraCommand(
            state="TRACKING",
            direction=direction,
            command_x=command_x,
            command_y=command_y,
            target_ids=tuple(item.track_id for item in decision.objects),
            target_count=len(decision.objects),
            total_stable_objects=decision.total_stable_objects,
            heads_fit=self.heads_fit,
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

    if controller.tracking_mode == "heads":
        for margin, colour in (
            (controller.head_clearance, (0, 165, 255)),
            (controller.head_clearance_stop, (0, 215, 255)),
        ):
            cv2.rectangle(
                frame,
                (int(width * margin), int(height * margin)),
                (
                    int(width * (1.0 - margin)),
                    int(height * (1.0 - margin)),
                ),
                colour,
                1,
            )
    elif controller.tracking_mode == "safe-frame":
        start_margin = controller.safe_frame_start_margin
        stop_margin = controller.safe_frame_stop_margin
        edge_guard = controller.safe_frame_edge_guard
        cv2.rectangle(
            frame,
            (int(width * edge_guard), int(height * edge_guard)),
            (
                int(width * (1.0 - edge_guard)),
                int(height * (1.0 - edge_guard)),
            ),
            (0, 0, 255),
            1,
        )
        cv2.rectangle(
            frame,
            (int(width * start_margin), int(height * start_margin)),
            (
                int(width * (1.0 - start_margin)),
                int(height * (1.0 - start_margin)),
            ),
            (0, 165, 255),
            1,
        )
        cv2.rectangle(
            frame,
            (int(width * stop_margin), int(height * stop_margin)),
            (
                int(width * (1.0 - stop_margin)),
                int(height * (1.0 - stop_margin)),
            ),
            (255, 255, 0),
            2,
        )
    else:
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
        if controller.tracking_mode == "heads":
            for item in decision.objects:
                hx1, hy1, hx2, hy2 = (
                    int(value) for value in controller.head_box(item)
                )
                cv2.rectangle(frame, (hx1, hy1), (hx2, hy2), (255, 128, 0), 2)
            cluster = controller.smoothed_group_box or controller.framing_box(
                decision
            )
            cx1, cy1, cx2, cy2 = (int(value) for value in cluster)
            cluster_colour = (255, 255, 255) if command.heads_fit else (0, 0, 255)
            cv2.rectangle(frame, (cx1, cy1), (cx2, cy2), cluster_colour, 2)
            cv2.putText(
                frame,
                "HEADS" if command.heads_fit else "HEADS DO NOT FIT",
                (cx1, max(18, cy1 - 8)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.52,
                cluster_colour,
                2,
                cv2.LINE_AA,
            )
            if controller.smoothed_head_median is not None:
                median_x = int(controller.smoothed_head_median[0])
                median_y = int(controller.smoothed_head_median[1])
                cv2.drawMarker(
                    frame,
                    (median_x, median_y),
                    (255, 0, 255),
                    cv2.MARKER_CROSS,
                    22,
                    2,
                )
            anchor_y = int(height * controller.head_anchor_ratio)
            half_width = int(width * controller.deadzone_width / 2.0)
            half_height = int(height * controller.deadzone_height / 2.0)
            cv2.rectangle(
                frame,
                (center[0] - half_width, anchor_y - half_height),
                (center[0] + half_width, anchor_y + half_height),
                (255, 255, 0),
                2,
            )
        elif controller.tracking_mode == "safe-frame":
            for item in decision.objects:
                hx1, hy1, hx2, hy2 = (
                    int(value) for value in controller.head_box(item)
                )
                cv2.rectangle(frame, (hx1, hy1), (hx2, hy2), (255, 128, 0), 2)
            fx1, fy1, fx2, fy2 = (
                int(value) for value in controller.framing_box(decision)
            )
            cv2.rectangle(frame, (fx1, fy1), (fx2, fy2), (255, 255, 255), 2)
            cv2.putText(
                frame,
                f"HEAD FRAME {controller.head_ratio:.0%}",
                (fx1, max(18, fy1 - 8)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.52,
                (255, 255, 255),
                2,
                cv2.LINE_AA,
            )
            for track_x_value, track_y_value in controller.tracking_points(
                decision
            ):
                track_x = int(track_x_value)
                track_y = int(track_y_value)
                cv2.drawMarker(
                    frame,
                    (track_x, track_y),
                    (255, 0, 255),
                    cv2.MARKER_CROSS,
                    20,
                    2,
                )
                cv2.putText(
                    frame,
                    f"SAFE POINT {controller.subject_y_ratio:.0%}",
                    (track_x, max(18, track_y - 8)),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.52,
                    (255, 0, 255),
                    2,
                    cv2.LINE_AA,
                )

    if (
        controller.tracking_mode == "center"
        and controller.smoothed_target is not None
        and command.state == "TRACKING"
    ):
        smooth_center = (
            int(controller.smoothed_target[0]),
            int(controller.smoothed_target[1]),
        )
        cv2.line(frame, center, smooth_center, (0, 0, 255), 2)
        cv2.circle(frame, smooth_center, 7, (0, 0, 255), -1)

    mode = "LIMITED" if command.limited_group else "ALL"
    lines = (
        (
            f"state={command.state} command={command.direction} "
            f"tracking={controller.tracking_mode}"
        ),
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
    dashboard = None
    if args.dashboard_port:
        from servo_dashboard import ServoDashboard

        dashboard = ServoDashboard(
            host=args.dashboard_host,
            port=args.dashboard_port,
            device_id=args.device_id,
            mqtt_host=args.mqtt_host,
            mqtt_port=args.mqtt_port,
            mqtt_username=args.mqtt_username,
            mqtt_password=args.mqtt_password,
            log_path=args.dashboard_log,
            event_dir=args.dashboard_event_dir,
            yamnet_diagnostics_path=args.dashboard_yamnet_diagnostics,
            jpeg_width=args.dashboard_frame_width,
            jpeg_quality=args.dashboard_jpeg_quality,
            frame_interval_seconds=args.dashboard_frame_interval,
        )
        dashboard.start()
    histories: dict[int, TrackLife] = {}
    selector = StableGroupSelector(args.switch_frames)
    controller = AutoFrameController(
        ema_alpha=args.ema_alpha,
        deadzone_width=args.deadzone_width,
        deadzone_height=args.deadzone_height,
        subject_y_ratio=args.subject_y_ratio,
        home_after_seconds=args.home_after_seconds,
        tracking_mode=args.tracking_mode,
        safe_frame_start_margin=args.safe_frame_start_margin,
        safe_frame_stop_margin=args.safe_frame_stop_margin,
        safe_frame_edge_guard=args.safe_frame_edge_guard,
        target_loss_follow_seconds=args.target_loss_follow_seconds,
        head_ratio=args.head_ratio,
        head_anchor_ratio=args.head_anchor_ratio,
        head_clearance=args.head_clearance,
        head_clearance_stop=args.head_clearance_stop,
        head_settle_ratio=args.head_settle_ratio,
        head_memory_seconds=args.head_memory_seconds,
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
    print(
        "Model runtime: "
        + ("TensorRT" if model_path.suffix.lower() == ".engine" else "PyTorch")
    )
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
                include_all=args.tracking_mode in {"safe-frame", "heads"},
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
                (
                    control_output is not None
                    or vision_publisher is not None
                    or dashboard is not None
                )
                and timeline_now - last_command_at >= args.command_interval
            ):
                command_payload = command.as_payload(frame_count)
                command_payload["device_id"] = args.device_id
                command_payload["frame_width"] = width
                command_payload["frame_height"] = height
                command_payload["object_counts"] = {
                    class_name: sum(
                        item.class_name == class_name for item in stable_objects
                    )
                    for class_name in TARGET_CLASSES.values()
                }
                command_payload["track_ids"] = [
                    item.track_id for item in stable_objects
                ]
                command_payload["objects"] = [
                    {
                        "track_id": item.track_id,
                        "class_name": item.class_name,
                        "confidence": round(item.confidence, 4),
                        "center_x": round(item.center[0] / max(width, 1), 6),
                        "center_y": round(item.center[1] / max(height, 1), 6),
                        "box": [
                            round(item.box[0] / max(width, 1), 6),
                            round(item.box[1] / max(height, 1), 6),
                            round(item.box[2] / max(width, 1), 6),
                            round(item.box[3] / max(height, 1), 6),
                        ],
                    }
                    for item in stable_objects
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
                if dashboard is not None:
                    dashboard.update(
                        command_payload,
                        annotated_frame,
                        now_monotonic=wall_now,
                    )
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
        if dashboard is not None:
            dashboard.close()
        cv2.destroyAllWindows()

    elapsed = max(time.monotonic() - started_at, 1e-6)
    print(f"Finished: {frame_count} frames, average {frame_count / elapsed:.1f} FPS")


def main() -> None:
    run(parse_args())


if __name__ == "__main__":
    main()
