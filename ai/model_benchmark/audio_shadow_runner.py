#!/usr/bin/env python3
"""Run EfficientAT on the shared RTSP audio in shadow or operational mode.

Shadow mode is the default and writes prediction and virtual-event JSONL
records only: no trigger file, no MQTT, no upload.  Operational mode adds the
trigger JSON the segment uploader already consumes plus MQTT publication, so
EfficientAT can hold event authority in place of YAMNet.

Side effects are opt-in and fail closed.  `--operational` is required before
`--event-dir` or `--mqtt-host` are accepted at all, so a shadow invocation
cannot create an event even if an operational flag is passed by mistake.
"""

from __future__ import annotations

import argparse
from array import array
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import math
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
from typing import Any
import uuid

SCRIPT_DIR = Path(__file__).resolve().parent
AI_DIR = SCRIPT_DIR.parent
YAMNET_DIR = AI_DIR / "yamnet"
if str(YAMNET_DIR) not in sys.path:
    sys.path.insert(0, str(YAMNET_DIR))

from audio_prediction_runner import (  # noqa: E402
    EfficientAtPredictor,
    event_class_indices,
    sha256_file,
)
from audio_event_trigger import write_audio_event_trigger  # noqa: E402
from ffmpeg_audio_stream import (  # noqa: E402
    ReconnectingFfmpegAudio,
    build_audio_command,
    detect_rtsp_timeout_option,
    redact_stream_url,
)


SCHEMA_VERSION = "0.1"
MODEL_KIND = "efficientat-mn10"
MODEL_NAME = "EfficientAT MN10"
SAMPLE_RATE = 32_000


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def isoformat(value: datetime) -> str:
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def percentile(values: list[float], ratio: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * ratio
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


class JsonlWriter:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self._lock = threading.Lock()
        self._output = path.open("a", encoding="utf-8", buffering=1)

    def write(self, payload: dict[str, Any]) -> None:
        line = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        with self._lock:
            self._output.write(line + "\n")

    def close(self) -> None:
        with self._lock:
            self._output.close()


class SlidingAudioBuffer:
    """Thread-safe trailing audio window paced by newly received samples."""

    def __init__(self, window_samples: int, hop_samples: int) -> None:
        if window_samples <= 0 or hop_samples <= 0:
            raise ValueError("window and hop samples must be positive")
        self.window_samples = window_samples
        self.hop_samples = hop_samples
        self._maximum_samples = window_samples + hop_samples * 2
        self._values = array("f")
        self._new_samples = 0
        self._emitted_once = False
        self._condition = threading.Condition()

    def append(self, values: Any) -> None:
        samples = array("f", values)
        if not samples:
            return
        with self._condition:
            self._values.extend(samples)
            if len(self._values) > self._maximum_samples:
                del self._values[: len(self._values) - self._maximum_samples]
            self._new_samples += len(samples)
            self._condition.notify_all()

    def reset(self) -> None:
        with self._condition:
            self._values = array("f")
            self._new_samples = 0
            self._emitted_once = False
            self._condition.notify_all()

    def wait_for_window(
        self,
        stop: threading.Event,
        timeout_seconds: float = 1.0,
    ) -> array | None:
        with self._condition:
            ready = lambda: (
                len(self._values) >= self.window_samples
                and (
                    not self._emitted_once
                    or self._new_samples >= self.hop_samples
                )
            )
            if not ready() and not stop.is_set():
                self._condition.wait(timeout_seconds)
            if stop.is_set() or not ready():
                return None
            window = array("f", self._values[-self.window_samples :])
            if self._emitted_once:
                self._new_samples = max(
                    0,
                    self._new_samples - self.hop_samples,
                )
            else:
                self._new_samples = 0
                self._emitted_once = True
            return window


@dataclass(frozen=True)
class GateResult:
    positive: bool
    positive_windows: int
    triggered: bool
    cooldown_remaining_seconds: float


class VirtualEventGate:
    """Apply the same consecutive-window and cooldown policy as tuning."""

    def __init__(
        self,
        threshold: float,
        required_windows: int,
        cooldown_seconds: float,
    ) -> None:
        if not 0.0 <= threshold <= 1.0:
            raise ValueError("threshold must be between zero and one")
        if required_windows <= 0:
            raise ValueError("required windows must be positive")
        if cooldown_seconds < 0:
            raise ValueError("cooldown cannot be negative")
        self.threshold = threshold
        self.required_windows = required_windows
        self.cooldown_seconds = cooldown_seconds
        self.positive_windows = 0
        self.last_event_at: float | None = None

    def observe(self, score: float, now: float) -> GateResult:
        positive = score >= self.threshold
        if positive:
            self.positive_windows += 1
        else:
            self.positive_windows = 0

        cooldown_remaining = 0.0
        if self.last_event_at is not None:
            cooldown_remaining = max(
                0.0,
                self.cooldown_seconds - (now - self.last_event_at),
            )
        triggered = (
            self.positive_windows >= self.required_windows
            and cooldown_remaining <= 0.0
        )
        observed_windows = self.positive_windows
        if triggered:
            self.last_event_at = now
            self.positive_windows = 0
        return GateResult(
            positive=positive,
            positive_windows=observed_windows,
            triggered=triggered,
            cooldown_remaining_seconds=cooldown_remaining,
        )


def git_commit(repository: Path) -> str | None:
    completed = subprocess.run(
        ["git", "-C", str(repository), "rev-parse", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    value = completed.stdout.strip()
    return value if completed.returncode == 0 and value else None


def event_score(
    scores: Any,
    indices: tuple[int, ...],
    class_names: list[str],
) -> tuple[float, str]:
    selected = max(indices, key=lambda index: float(scores[index]))
    return float(scores[selected]), class_names[selected]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stream-url", required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--source-repo", type=Path, required=True)
    parser.add_argument("--class-map", type=Path)
    parser.add_argument("--diagnostics-jsonl", type=Path, required=True)
    parser.add_argument("--model-name", default=MODEL_NAME)
    parser.add_argument("--model-sha256")
    parser.add_argument("--source-commit")
    parser.add_argument("--device", default="cuda")
    parser.add_argument(
        "--precision",
        choices=("auto", "fp16", "fp32"),
        default="fp16",
    )
    parser.add_argument("--context-seconds", type=float, default=10.0)
    parser.add_argument("--hop-seconds", type=float, default=2.5)
    parser.add_argument(
        "--laughter-threshold",
        type=float,
        # Field-corrected value, not the dev-set argmax (0.01691491). That
        # argmax fired on ordinary indoor conversation, which scores 0.072 on
        # this model. The launcher passes this explicitly; the default only
        # covers manual runs, and a manual run that can now hold event
        # authority must not silently pick the value that over-fires.
        default=0.03,
    )
    parser.add_argument("--laughter-consecutive", type=int, default=1)
    parser.add_argument(
        "--clap-threshold",
        type=float,
        default=0.08725224,
    )
    parser.add_argument("--clap-consecutive", type=int, default=1)
    parser.add_argument("--cooldown-seconds", type=float, default=12.0)
    parser.add_argument(
        "--operational",
        action="store_true",
        help=(
            "Grant event authority: write trigger files and publish MQTT. "
            "Without this flag the process cannot create any event."
        ),
    )
    parser.add_argument(
        "--event-dir",
        type=Path,
        help="Trigger directory read by the segment uploader.",
    )
    parser.add_argument("--clip-seconds", type=float, default=60.0)
    parser.add_argument("--device-id")
    parser.add_argument("--mqtt-host")
    parser.add_argument("--mqtt-port", type=int, default=1883)
    parser.add_argument("--mqtt-username")
    parser.add_argument("--mqtt-password")
    parser.add_argument(
        "--enable-clap-events",
        action="store_true",
        help=(
            "Emit operational CLAP events. Shadow virtual events always "
            "include clap regardless of this flag."
        ),
    )
    parser.add_argument("--block-seconds", type=float, default=0.5)
    parser.add_argument("--ffmpeg-path", default="/usr/bin/ffmpeg")
    parser.add_argument("--stream-read-timeout-seconds", type=float, default=5.0)
    parser.add_argument("--reconnect-initial-seconds", type=float, default=1.0)
    parser.add_argument("--reconnect-max-seconds", type=float, default=10.0)
    parser.add_argument("--max-windows", type=int)
    return parser.parse_args(argv)


def validate_args(args: argparse.Namespace) -> None:
    for name in ("context_seconds", "hop_seconds", "block_seconds"):
        if float(getattr(args, name)) <= 0:
            raise SystemExit(f"--{name.replace('_', '-')} must be positive")
    if args.hop_seconds > args.context_seconds:
        raise SystemExit("--hop-seconds cannot exceed --context-seconds")
    if args.stream_read_timeout_seconds <= 0:
        raise SystemExit("--stream-read-timeout-seconds must be positive")
    if args.reconnect_initial_seconds <= 0:
        raise SystemExit("--reconnect-initial-seconds must be positive")
    if args.reconnect_max_seconds < args.reconnect_initial_seconds:
        raise SystemExit(
            "--reconnect-max-seconds must be at least reconnect-initial-seconds"
        )
    if args.max_windows is not None and args.max_windows <= 0:
        raise SystemExit("--max-windows must be positive")
    if args.operational:
        if args.event_dir is None and args.mqtt_host is None:
            raise SystemExit(
                "--operational requires --event-dir and/or --mqtt-host"
            )
        if args.clip_seconds <= 0:
            raise SystemExit("--clip-seconds must be positive")
        if not 1 <= args.mqtt_port <= 65_535:
            raise SystemExit("--mqtt-port must be between 1 and 65535")
        if args.mqtt_host and not (args.device_id or "").strip():
            raise SystemExit("--device-id is required with --mqtt-host")
    else:
        # Fail closed: a shadow run must not carry operational plumbing even
        # by accident, so reject the arguments rather than ignoring them.
        for name in ("event_dir", "mqtt_host"):
            if getattr(args, name) is not None:
                flag = name.replace("_", "-")
                raise SystemExit(f"--{flag} requires --operational")
    VirtualEventGate(
        args.laughter_threshold,
        args.laughter_consecutive,
        args.cooldown_seconds,
    )
    VirtualEventGate(
        args.clap_threshold,
        args.clap_consecutive,
        args.cooldown_seconds,
    )


def run(args: argparse.Namespace) -> int:
    import numpy as np

    validate_args(args)
    operational = bool(args.operational)
    event_dir = (
        args.event_dir.expanduser().resolve()
        if operational and args.event_dir is not None
        else None
    )
    mqtt_enabled = operational and bool(args.mqtt_host)
    model_path = args.model.expanduser().resolve()
    source_repo = args.source_repo.expanduser().resolve()
    class_map = (
        args.class_map.expanduser().resolve()
        if args.class_map is not None
        else source_repo / "metadata" / "class_labels_indices.csv"
    )
    diagnostics_path = args.diagnostics_jsonl.expanduser().resolve()
    for required in (model_path, source_repo, class_map):
        if not required.exists():
            raise SystemExit(f"required shadow asset not found: {required}")

    actual_model_sha256 = sha256_file(model_path)
    if (
        args.model_sha256
        and actual_model_sha256.casefold() != args.model_sha256.casefold()
    ):
        raise SystemExit(
            "EfficientAT model checksum mismatch: "
            f"expected={args.model_sha256} actual={actual_model_sha256}"
        )
    actual_source_commit = git_commit(source_repo)
    if args.source_commit and actual_source_commit != args.source_commit:
        raise SystemExit(
            "EfficientAT source commit mismatch: "
            f"expected={args.source_commit} actual={actual_source_commit}"
        )

    writer = JsonlWriter(diagnostics_path)
    stop = threading.Event()

    def request_stop(signum: int, frame: Any) -> None:
        del signum, frame
        stop.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    writer.write(
        {
            "schemaVersion": SCHEMA_VERSION,
            "recordType": "startup",
            "observedAt": isoformat(utc_now()),
            "mode": "operational" if operational else "shadow-only",
            "operationalAuthority": operational,
            "sideEffects": {
                "trigger": event_dir is not None,
                "mqtt": mqtt_enabled,
                "upload": False,
                "api": False,
            },
            "model": {
                "name": args.model_name,
                "kind": MODEL_KIND,
                "runtime": "pytorch",
                "path": str(model_path),
                "sha256": actual_model_sha256,
                "sourceRepository": str(source_repo),
                "sourceCommit": actual_source_commit,
            },
            "configuration": {
                "sampleRate": SAMPLE_RATE,
                "contextSeconds": args.context_seconds,
                "hopSeconds": args.hop_seconds,
                "device": args.device,
                "requestedPrecision": args.precision,
                "cooldownSeconds": args.cooldown_seconds,
                "eventDir": str(event_dir) if event_dir is not None else None,
                "clipSeconds": args.clip_seconds if operational else None,
                "clapEventsEnabled": (
                    bool(args.enable_clap_events) if operational else None
                ),
                "events": {
                    "laughter": {
                        "threshold": args.laughter_threshold,
                        "requiredConsecutiveWindows": args.laughter_consecutive,
                    },
                    "clap": {
                        "threshold": args.clap_threshold,
                        "requiredConsecutiveWindows": args.clap_consecutive,
                    },
                },
            },
        }
    )

    mode_label = "operational" if operational else "shadow"
    print(f"Loading EfficientAT {mode_label} model", flush=True)
    predictor = EfficientAtPredictor(
        model_path,
        source_repo,
        class_map,
        args.device,
        args.precision,
    )
    laughter_indices = event_class_indices(
        predictor.class_names,
        "laughter",
    )
    clap_indices = event_class_indices(predictor.class_names, "clap")
    window_samples = int(round(SAMPLE_RATE * args.context_seconds))
    hop_samples = int(round(SAMPLE_RATE * args.hop_seconds))
    block_samples = int(round(SAMPLE_RATE * args.block_seconds))
    audio_buffer = SlidingAudioBuffer(window_samples, hop_samples)
    laughter_gate = VirtualEventGate(
        args.laughter_threshold,
        args.laughter_consecutive,
        args.cooldown_seconds,
    )
    clap_gate = VirtualEventGate(
        args.clap_threshold,
        args.clap_consecutive,
        args.cooldown_seconds,
    )
    event_settings = {
        "laughter": (args.laughter_threshold, args.laughter_consecutive),
        "clap": (args.clap_threshold, args.clap_consecutive),
    }

    publisher = None
    if mqtt_enabled:
        from mqtt_event_publisher import MqttEventPublisher

        publisher = MqttEventPublisher(
            host=args.mqtt_host,
            port=args.mqtt_port,
            device_id=args.device_id,
            username=args.mqtt_username,
            password=args.mqtt_password,
            component="efficientat",
        )

    def stream_log(message: str) -> None:
        print(message, flush=True)
        if "unavailable" in message.casefold():
            audio_buffer.reset()
        writer.write(
            {
                "schemaVersion": SCHEMA_VERSION,
                "recordType": "stream-status",
                "observedAt": isoformat(utc_now()),
                "detail": message,
            }
        )

    def on_block(block: bytes) -> None:
        audio_buffer.append(np.frombuffer(block, dtype="<f4").copy())

    timeout_option = detect_rtsp_timeout_option(args.ffmpeg_path)
    command = build_audio_command(
        args.ffmpeg_path,
        args.stream_url,
        SAMPLE_RATE,
        args.stream_read_timeout_seconds,
        rtsp_timeout_option=timeout_option,
    )
    stream = ReconnectingFfmpegAudio(
        command,
        block_bytes=block_samples * 4,
        on_block=on_block,
        reconnect_initial_seconds=args.reconnect_initial_seconds,
        reconnect_max_seconds=args.reconnect_max_seconds,
        log=stream_log,
        safe_source=redact_stream_url(args.stream_url),
    )
    stream.start()
    print(
        f"EfficientAT {mode_label} ready: "
        f"context={args.context_seconds:.3f}s hop={args.hop_seconds:.3f}s "
        f"laughter={args.laughter_threshold:.8f}/"
        f"{args.laughter_consecutive} "
        f"clap={args.clap_threshold:.8f}/{args.clap_consecutive} "
        f"trigger={'on' if event_dir is not None else 'off'} "
        f"mqtt={'on' if mqtt_enabled else 'off'} "
        f"clapEvents={'on' if operational and args.enable_clap_events else 'off'}",
        flush=True,
    )

    inference_values: list[float] = []
    window_index = 0
    virtual_event_count = {"laughter": 0, "clap": 0}
    try:
        while not stop.is_set():
            buffered_waveform = audio_buffer.wait_for_window(stop)
            if buffered_waveform is None:
                continue
            waveform = np.asarray(buffered_waveform, dtype=np.float32)
            detected_at = utc_now()
            scores, inference_ms = predictor.predict(waveform)
            scores = np.asarray(scores, dtype=np.float32).reshape(-1)
            if scores.size != len(predictor.class_names):
                raise RuntimeError(
                    "EfficientAT score count does not match its class map"
                )
            if not np.all(np.isfinite(scores)):
                raise RuntimeError("EfficientAT returned non-finite scores")
            inference_values.append(float(inference_ms))
            laughter_score, laughter_class = event_score(
                scores,
                laughter_indices,
                predictor.class_names,
            )
            clap_score, clap_class = event_score(
                scores,
                clap_indices,
                predictor.class_names,
            )
            now = time.monotonic()
            laughter = laughter_gate.observe(laughter_score, now)
            clap = clap_gate.observe(clap_score, now)
            top_index = int(np.argmax(scores))
            window_started_at = detected_at - timedelta(
                seconds=args.context_seconds
            )
            rms = float(np.sqrt(np.mean(np.square(waveform))))
            record = {
                "schemaVersion": SCHEMA_VERSION,
                "recordType": "prediction",
                "observedAt": isoformat(detected_at),
                "model": args.model_name,
                "runtime": "pytorch",
                "precision": predictor.precision,
                "windowIndex": window_index,
                "windowStartedAt": isoformat(window_started_at),
                "windowEndedAt": isoformat(detected_at),
                "contextSeconds": args.context_seconds,
                "hopSeconds": args.hop_seconds,
                "inferenceMs": round(float(inference_ms), 3),
                "rms": round(rms, 6),
                "topClass": predictor.class_names[top_index],
                "topScore": round(float(scores[top_index]), 6),
                # The servo dashboard and the stack's readiness probe both read
                # the YAMNet diagnostics shape. Mirroring the laughter decision
                # under those key names lets EfficientAT drive them unchanged.
                "selectedScore": round(laughter_score, 8),
                "selectedClass": laughter_class,
                "selectedAggregation": "window",
                "threshold": args.laughter_threshold,
                "positiveStreak": laughter.positive_windows,
                "wouldTrigger": laughter.triggered,
                "events": {
                    "laughter": {
                        "score": round(laughter_score, 8),
                        "className": laughter_class,
                        "threshold": args.laughter_threshold,
                        "positive": laughter.positive,
                        "positiveWindows": laughter.positive_windows,
                        "wouldTrigger": laughter.triggered,
                        "cooldownRemainingSeconds": round(
                            laughter.cooldown_remaining_seconds,
                            3,
                        ),
                    },
                    "clap": {
                        "score": round(clap_score, 8),
                        "className": clap_class,
                        "threshold": args.clap_threshold,
                        "positive": clap.positive,
                        "positiveWindows": clap.positive_windows,
                        "wouldTrigger": clap.triggered,
                        "cooldownRemainingSeconds": round(
                            clap.cooldown_remaining_seconds,
                            3,
                        ),
                    },
                },
            }
            writer.write(record)

            for event_type, gate, score, class_name in (
                ("laughter", laughter, laughter_score, laughter_class),
                ("clap", clap, clap_score, clap_class),
            ):
                if not gate.triggered:
                    continue
                if (
                    operational
                    and event_type == "clap"
                    and not args.enable_clap_events
                ):
                    continue
                virtual_event_count[event_type] += 1
                threshold, consecutive = event_settings[event_type]
                if not operational:
                    writer.write(
                        {
                            "schemaVersion": SCHEMA_VERSION,
                            "recordType": "virtual-event",
                            "observedAt": isoformat(detected_at),
                            "detectedAt": isoformat(detected_at),
                            "virtualEventId": f"shadow-{uuid.uuid4()}",
                            "eventType": event_type.upper(),
                            "confidence": round(score, 8),
                            "className": class_name,
                            "windowIndex": window_index,
                            "windowStartedAt": isoformat(window_started_at),
                            "windowEndedAt": isoformat(detected_at),
                            "operationalAuthority": False,
                        }
                    )
                    print(
                        "Virtual event only: "
                        f"type={event_type.upper()} score={score:.6f} "
                        f"class={class_name}",
                        flush=True,
                    )
                    continue

                event_id = str(uuid.uuid4())
                # A model returning a value a hair outside [0, 1] must not kill
                # the detector, so clamp before the trigger schema validates it.
                confidence = min(1.0, max(0.0, float(score)))
                if event_dir is not None:
                    write_audio_event_trigger(
                        event_dir,
                        event_id=event_id,
                        event_type=event_type.upper(),
                        occurred_at=detected_at,
                        confidence=confidence,
                        class_name=class_name,
                        clip_seconds=args.clip_seconds,
                        metadata={
                            "model": MODEL_KIND,
                            "threshold": threshold,
                            "contextSeconds": args.context_seconds,
                            "hopSeconds": args.hop_seconds,
                        },
                    )
                if publisher is not None:
                    try:
                        publisher.publish_event(
                            event_type=event_type,
                            event_id=event_id,
                            score=confidence,
                            class_name=class_name,
                            threshold=threshold,
                            consecutive=consecutive,
                            monotonic_ns=time.monotonic_ns(),
                            model_name=args.model_name,
                        )
                    except Exception as exc:
                        # A broker hiccup must not discard the trigger that was
                        # already written; the uploader is the durable path.
                        print(
                            f"MQTT event publish failed: {exc}",
                            file=sys.stderr,
                            flush=True,
                        )
                writer.write(
                    {
                        "schemaVersion": SCHEMA_VERSION,
                        "recordType": "event",
                        "observedAt": isoformat(detected_at),
                        "detectedAt": isoformat(detected_at),
                        "eventId": event_id,
                        "eventType": event_type.upper(),
                        "confidence": round(confidence, 8),
                        "className": class_name,
                        "windowIndex": window_index,
                        "windowStartedAt": isoformat(window_started_at),
                        "windowEndedAt": isoformat(detected_at),
                        "operationalAuthority": True,
                    }
                )
                print(
                    "Event: "
                    f"type={event_type.upper()} score={confidence:.6f} "
                    f"class={class_name} id={event_id}",
                    flush=True,
                )
            window_index += 1
            print(
                f"EfficientAT {mode_label} prediction: "
                f"window={window_index} laughter={laughter_score:.6f} "
                f"clap={clap_score:.6f} inference={inference_ms:.1f}ms",
                flush=True,
            )
            if args.max_windows is not None and window_index >= args.max_windows:
                break
    finally:
        stop.set()
        stream.close()
        if publisher is not None:
            try:
                publisher.close()
            except Exception as exc:
                print(f"MQTT close failed: {exc}", file=sys.stderr, flush=True)
        mean_latency = (
            sum(inference_values) / len(inference_values)
            if inference_values
            else None
        )
        count_key = "eventCount" if operational else "virtualEventCount"
        writer.write(
            {
                "schemaVersion": SCHEMA_VERSION,
                "recordType": "shutdown",
                "observedAt": isoformat(utc_now()),
                "mode": "operational" if operational else "shadow-only",
                "predictionCount": window_index,
                count_key: virtual_event_count,
                "latencyMeanMs": (
                    round(mean_latency, 3)
                    if mean_latency is not None
                    else None
                ),
                "latencyP95Ms": (
                    round(percentile(inference_values, 0.95), 3)
                    if inference_values
                    else None
                ),
            }
        )
        writer.close()
    return 0


def main(argv: list[str] | None = None) -> int:
    return run(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())
