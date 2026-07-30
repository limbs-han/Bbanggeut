#!/usr/bin/env python3
"""Detect a registered wake name with a strictly local Faster-Whisper model."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import queue
import sys
import time
import uuid
from typing import Any

from audio_event_detection import WakeNameDetector
from audio_event_trigger import write_audio_event_trigger
from ffmpeg_audio_stream import (
    ReconnectingFfmpegAudio,
    build_audio_command,
    detect_rtsp_timeout_option,
    redact_stream_url,
)
from wake_name_profile import load_and_validate_profile


SAMPLE_RATE = 16_000
BLOCK_SECONDS = 0.5


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile-dir", type=Path, required=True)
    parser.add_argument(
        "--model-dir",
        type=Path,
        required=True,
        help="Local CTranslate2 Whisper model directory; downloads are disabled.",
    )
    parser.add_argument("--stream-url", required=True)
    parser.add_argument("--event-dir", type=Path, required=True)
    parser.add_argument("--device-id", required=True)
    parser.add_argument("--threshold", type=float, default=0.82)
    parser.add_argument("--cooldown", type=float, default=12.0)
    parser.add_argument("--window-seconds", type=float, default=3.0)
    parser.add_argument("--hop-seconds", type=float, default=1.5)
    parser.add_argument("--clip-seconds", type=float, default=60.0)
    parser.add_argument("--device", default=os.getenv("WAKE_NAME_ASR_DEVICE", "cpu"))
    parser.add_argument(
        "--compute-type",
        default=os.getenv("WAKE_NAME_ASR_COMPUTE_TYPE", "int8"),
    )
    parser.add_argument("--diagnostics-jsonl", type=Path)
    parser.add_argument("--diagnostics-only", action="store_true")
    parser.add_argument("--mqtt-host", default=os.getenv("MQTT_HOST"))
    parser.add_argument(
        "--mqtt-port",
        type=int,
        default=int(os.getenv("MQTT_PORT", "1883")),
    )
    parser.add_argument("--mqtt-username", default=os.getenv("MQTT_USERNAME"))
    parser.add_argument("--mqtt-password", default=os.getenv("MQTT_PASSWORD"))
    parser.add_argument(
        "--reconnect-initial-seconds",
        type=float,
        default=1.0,
    )
    parser.add_argument(
        "--reconnect-max-seconds",
        type=float,
        default=10.0,
    )
    parser.add_argument(
        "--stream-read-timeout-seconds",
        type=float,
        default=5.0,
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if not args.model_dir.expanduser().is_dir():
        raise SystemExit(
            "--model-dir must be a local Faster-Whisper model directory"
        )
    if not 0.0 <= args.threshold <= 1.0:
        raise SystemExit("--threshold must be between 0 and 1")
    if args.cooldown < 0:
        raise SystemExit("--cooldown cannot be negative")
    if args.window_seconds <= 0 or args.hop_seconds <= 0:
        raise SystemExit("--window-seconds and --hop-seconds must be positive")
    if args.hop_seconds > args.window_seconds:
        raise SystemExit("--hop-seconds cannot exceed --window-seconds")
    if args.clip_seconds <= 0:
        raise SystemExit("--clip-seconds must be positive")
    if not 1 <= args.mqtt_port <= 65_535:
        raise SystemExit("--mqtt-port must be between 1 and 65535")


def require_packages() -> tuple[Any, Any]:
    try:
        import numpy as np
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise SystemExit(
            "Local wake-name packages are missing. Install "
            "requirements-wake-name.txt in a dedicated virtual environment."
        ) from exc
    return np, WhisperModel


def run(args: argparse.Namespace) -> None:
    validate_args(args)
    profile = load_and_validate_profile(args.profile_dir)
    phrase = str(profile["wakePhrase"])
    locale = str(profile["locale"])
    language = locale.split("-", 1)[0].casefold()
    detector = WakeNameDetector(
        phrase=phrase,
        threshold=args.threshold,
        cooldown_seconds=args.cooldown,
    )
    np, whisper_model = require_packages()
    model = whisper_model(
        str(args.model_dir.expanduser().resolve()),
        device=args.device,
        compute_type=args.compute_type,
        local_files_only=True,
    )

    diagnostics_output = None
    if args.diagnostics_jsonl is not None:
        diagnostics_path = args.diagnostics_jsonl.expanduser().resolve()
        diagnostics_path.parent.mkdir(parents=True, exist_ok=True)
        diagnostics_output = diagnostics_path.open(
            "w",
            encoding="utf-8",
            buffering=1,
        )

    mqtt_publisher = None
    if args.mqtt_host and not args.diagnostics_only:
        from mqtt_event_publisher import MqttEventPublisher

        mqtt_publisher = MqttEventPublisher(
            host=args.mqtt_host,
            port=args.mqtt_port,
            device_id=args.device_id,
            username=args.mqtt_username,
            password=args.mqtt_password,
        )

    block_samples = int(round(SAMPLE_RATE * BLOCK_SECONDS))
    window_samples = int(round(SAMPLE_RATE * args.window_seconds))
    hop_samples = int(round(SAMPLE_RATE * args.hop_seconds))
    audio_queue: queue.Queue[Any] = queue.Queue(maxsize=16)
    buffer = np.empty(0, dtype=np.float32)
    samples_since_inference = 0

    ffmpeg_path = os.getenv("FFMPEG_PATH", "/usr/bin/ffmpeg")
    command = build_audio_command(
        ffmpeg_path,
        args.stream_url,
        SAMPLE_RATE,
        args.stream_read_timeout_seconds,
        rtsp_timeout_option=detect_rtsp_timeout_option(ffmpeg_path),
    )

    def handle_pcm_block(data: bytes) -> None:
        chunk = np.frombuffer(data, dtype="<f4").copy()
        try:
            audio_queue.put_nowait(chunk)
        except queue.Full:
            try:
                audio_queue.get_nowait()
            except queue.Empty:
                pass
            audio_queue.put_nowait(chunk)

    reader = ReconnectingFfmpegAudio(
        command,
        block_samples * 4,
        handle_pcm_block,
        reconnect_initial_seconds=args.reconnect_initial_seconds,
        reconnect_max_seconds=args.reconnect_max_seconds,
        safe_source=redact_stream_url(args.stream_url),
    )

    print(f"Wake-name profile: phrase={phrase!r} locale={locale}")
    print(f"Local ASR model: {args.model_dir.expanduser().resolve()}")
    print(f"Audio stream: {redact_stream_url(args.stream_url)}")
    reader.start()
    try:
        while True:
            chunk = audio_queue.get()
            buffer = np.concatenate((buffer, chunk))
            if len(buffer) > window_samples:
                buffer = buffer[-window_samples:]
            samples_since_inference += len(chunk)
            if (
                len(buffer) < window_samples
                or samples_since_inference < hop_samples
            ):
                continue
            samples_since_inference = 0

            inference_started = time.perf_counter()
            segments, _ = model.transcribe(
                buffer,
                language=language,
                beam_size=1,
                vad_filter=True,
                condition_on_previous_text=False,
            )
            transcript = " ".join(
                segment.text.strip()
                for segment in segments
                if segment.text.strip()
            ).strip()
            observed_at = time.monotonic()
            detection = detector.observe(transcript, observed_at)
            inference_ms = (
                time.perf_counter() - inference_started
            ) * 1_000.0

            if diagnostics_output is not None:
                diagnostics_output.write(
                    json.dumps(
                        {
                            "observedAt": datetime.now(timezone.utc)
                            .isoformat(timespec="milliseconds")
                            .replace("+00:00", "Z"),
                            "transcript": transcript,
                            "wakePhrase": phrase,
                            "matched": detection is not None,
                            "confidence": (
                                round(detection.confidence, 6)
                                if detection is not None
                                else None
                            ),
                            "inferenceMs": round(inference_ms, 3),
                        },
                        ensure_ascii=False,
                        separators=(",", ":"),
                    )
                    + "\n"
                )
            if detection is None:
                continue

            print(
                "Wake name detected! "
                f"phrase={detection.phrase!r} "
                f"confidence={detection.confidence:.3f}"
            )
            event_id = None
            if not args.diagnostics_only:
                event_id = str(uuid.uuid4())
                write_audio_event_trigger(
                    args.event_dir,
                    event_id=event_id,
                    event_type="WAKE_WORD",
                    occurred_at=datetime.now(timezone.utc),
                    confidence=detection.confidence,
                    class_name=detection.phrase,
                    clip_seconds=args.clip_seconds,
                    metadata={
                        "recognitionMode": (
                            "speaker-independent-local-asr"
                        ),
                        "locale": locale,
                    },
                )
                print(f"Local wake-name event: {event_id}")
            if mqtt_publisher is not None:
                mqtt_publisher.publish_event(
                    event_type="WAKE_WORD",
                    event_id=event_id,
                    score=detection.confidence,
                    class_name=detection.phrase,
                    threshold=args.threshold,
                    consecutive=1,
                    monotonic_ns=time.monotonic_ns(),
                    model_name="Faster-Whisper",
                    metadata={"locale": locale},
                )
    except KeyboardInterrupt:
        print("Wake-name detector stopped.")
    finally:
        reader.close()
        if mqtt_publisher is not None:
            mqtt_publisher.close()
        if diagnostics_output is not None:
            diagnostics_output.close()


def main() -> None:
    run(parse_args())


if __name__ == "__main__":
    main()
