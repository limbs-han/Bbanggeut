"""Detect laughter from a Jetson-connected microphone with Google's YAMNet."""

from __future__ import annotations

import argparse
import csv
from collections import deque
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
import queue
import sys
import time
import uuid
import wave
from pathlib import Path
from typing import Any

from ffmpeg_audio_stream import (
    ReconnectingFfmpegAudio,
    build_audio_command,
    detect_rtsp_timeout_option,
    redact_stream_url,
)
from audio_event_detection import (
    CLAP_CLASS_KEYWORDS,
    ConsecutiveClapDetector,
    count_impulsive_onsets,
    find_class_indices,
)
from audio_event_trigger import write_audio_event_trigger
from laughter_scoring import SCORE_AGGREGATIONS, summarize_laughter_scores

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

YAMNET_URL = "https://tfhub.dev/google/yamnet/1"
YAMNET_SAMPLE_RATE = 16_000
BLOCK_SECONDS = 0.48
WINDOW_SECONDS = 1.44
LAUGHTER_KEYWORDS = (
    "laughter",
    "laugh",
    "giggle",
    "snicker",
    "chuckle",
    "chortle",
)


def env_flag(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().casefold() in {"1", "true", "yes", "on"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="젯슨에 연결된 마이크의 소리를 YAMNet으로 분석해 웃음을 탐지합니다."
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="사용 가능한 오디오 장치 목록을 출력하고 종료합니다.",
    )
    parser.add_argument(
        "--device",
        help="입력 장치 번호 또는 장치 이름 일부입니다(기본값: 시스템 기본 입력).",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.25,
        help="웃음으로 판정할 최소 점수입니다(기본값: 0.25).",
    )
    parser.add_argument(
        "--consecutive",
        type=int,
        default=2,
        help="알림 전에 연속으로 기준을 넘어야 하는 횟수입니다(기본값: 2).",
    )
    parser.add_argument(
        "--cooldown",
        type=float,
        default=2.0,
        help="웃음 알림 사이의 최소 시간(초)입니다(기본값: 2.0).",
    )
    parser.add_argument(
        "--sample-rate",
        type=int,
        help="마이크 캡처 샘플레이트입니다(기본값: 장치 기본값).",
    )
    parser.add_argument(
        "--gain",
        type=float,
        default=1.0,
        help="추론 전에 적용할 입력 증폭 배율입니다(기본값: 1.0).",
    )
    parser.add_argument(
        "--score-aggregation",
        choices=SCORE_AGGREGATIONS,
        default=os.getenv("YAMNET_SCORE_AGGREGATION", "max"),
        help=(
            "시간 패치의 웃음 점수를 합치는 방식입니다: max, mean, p90 "
            "(기본값: max)."
        ),
    )
    parser.add_argument(
        "--diagnostics-jsonl",
        type=Path,
        help=(
            "각 추론의 max·mean·p90, RMS와 판정 결과를 저장할 JSONL 경로입니다."
        ),
    )
    parser.add_argument(
        "--diagnostics-only",
        action="store_true",
        help="판정은 기록하되 이벤트 파일과 MQTT 메시지는 생성하지 않습니다.",
    )
    parser.add_argument(
        "--model",
        default=YAMNET_URL,
        help="TensorFlow Hub URL 또는 내려받은 로컬 YAMNet 디렉터리입니다.",
    )
    parser.add_argument(
        "--cache-dir",
        default=str(Path.home() / ".cache" / "tfhub"),
        help="TensorFlow Hub 모델 캐시 디렉터리입니다.",
    )
    parser.add_argument(
        "--max-seconds",
        type=float,
        help="지정한 시간(초) 뒤 자동 종료합니다. 생략하면 Ctrl+C까지 실행합니다.",
    )
    parser.add_argument(
        "--mqtt-host",
        default=os.getenv("MQTT_HOST"),
        help="MQTT 브로커 주소입니다. 생략하면 MQTT를 사용하지 않습니다.",
    )
    parser.add_argument(
        "--mqtt-port",
        type=int,
        default=int(os.getenv("MQTT_PORT", "1883")),
        help="MQTT 브로커 포트입니다(기본값: 1883).",
    )
    parser.add_argument(
        "--mqtt-username",
        default=os.getenv("MQTT_USERNAME"),
        help="MQTT 사용자 이름입니다.",
    )
    parser.add_argument(
        "--mqtt-password",
        default=os.getenv("MQTT_PASSWORD"),
        help="MQTT 비밀번호입니다.",
    )
    parser.add_argument(
        "--device-id",
        default=os.getenv("DEVICE_ID", "homecam-001"),
        help="이벤트에 포함할 홈캠 장치 ID입니다(기본값: homecam-001).",
    )
    parser.add_argument(
        "--mqtt-topic",
        help="웃음 이벤트를 발행할 토픽입니다. 생략하면 장치 ID로 생성합니다.",
    )
    parser.add_argument(
        "--event-dir",
        type=Path,
        help="Write local laughter triggers and audio clips for edge upload.",
    )
    parser.add_argument(
        "--trigger-only",
        action="store_true",
        help=(
            "Write event triggers without buffering WAV clips. Use this when "
            "clips are extracted from compressed rolling recordings."
        ),
    )
    parser.add_argument(
        "--stream-url",
        default=os.getenv("YAMNET_SOURCE_URL"),
        help="Shared RTSP/UDP media URL. When set, audio is decoded by FFmpeg.",
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
        "--stream-read-timeout-seconds",
        type=float,
        default=float(os.getenv("STREAM_READ_TIMEOUT_SECONDS", "5")),
        help="RTSP socket read timeout in seconds (default: 5).",
    )
    parser.add_argument(
        "--clip-seconds",
        type=float,
        default=5.0,
        help="Seconds to retain before and after laughter (default: 5).",
    )
    parser.add_argument(
        "--enable-clap-events",
        action="store_true",
        default=env_flag("YAMNET_CLAP_ENABLED"),
        help=(
            "Enable consecutive-clap event triggers. Disabled by default "
            "until the Backend CLAP contract is deployed."
        ),
    )
    parser.add_argument(
        "--clap-threshold",
        type=float,
        default=float(os.getenv("YAMNET_CLAP_THRESHOLD", "0.30")),
        help="Minimum aggregated Clapping/Applause score (default: 0.30).",
    )
    parser.add_argument(
        "--clap-consecutive",
        type=int,
        default=int(os.getenv("YAMNET_CLAP_CONSECUTIVE", "2")),
        help="Required consecutive clap-positive windows (default: 2).",
    )
    parser.add_argument(
        "--clap-required-onsets",
        type=int,
        default=int(os.getenv("YAMNET_CLAP_REQUIRED_ONSETS", "2")),
        help="Required separated impulse attacks in the audio window (default: 2).",
    )
    parser.add_argument(
        "--clap-min-active-seconds",
        type=float,
        default=float(os.getenv("YAMNET_CLAP_MIN_ACTIVE_SECONDS", "0.4")),
        help="Minimum sustained clap activity in seconds (default: 0.4).",
    )
    parser.add_argument(
        "--clap-max-gap-seconds",
        type=float,
        default=float(os.getenv("YAMNET_CLAP_MAX_GAP_SECONDS", "0.75")),
        help="Maximum gap between clap-positive windows (default: 0.75).",
    )
    parser.add_argument(
        "--clap-cooldown",
        type=float,
        default=float(os.getenv("YAMNET_CLAP_COOLDOWN", "12")),
        help="Minimum seconds between clap events (default: 12).",
    )
    return parser.parse_args()


def log_stage(message: str) -> None:
    """Print an immediately-flushed startup checkpoint.

    Several startup steps (native library imports, model downloads) can take
    a long time or hang outright depending on the runtime environment (for
    example: a systemd service without a desktop audio session behaves very
    differently from an interactive SSH shell). Without a checkpoint printed
    *before* each risky step, a hang shows up as an empty log with no way to
    tell which step never finished. `-u`/unbuffered mode is assumed, but we
    flush explicitly anyway since these prints matter more than performance.
    """

    stamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
    print(f"[startup {stamp}] {message}", flush=True)


def require_audio_packages(
    *,
    need_sounddevice: bool = True,
) -> tuple[Any, Any | None]:
    log_stage("importing numpy")
    try:
        import numpy as np
    except ImportError as exc:
        raise SystemExit(
            "오디오 패키지를 불러오지 못했습니다. 다음 명령을 실행하세요:\n"
            "python -m pip install -r requirements-jetson.txt"
        ) from exc
    log_stage("numpy imported")

    sd = None
    if need_sounddevice:
        # Importing sounddevice initializes PortAudio. Some headless service
        # environments can behave differently from an interactive shell
        # during native audio initialization, so avoid that work entirely
        # when the selected RTSP path never uses sounddevice.
        log_stage("importing sounddevice (initializes PortAudio)")
        try:
            import sounddevice as sd
        except ImportError as exc:
            raise SystemExit(
                "오디오 패키지를 불러오지 못했습니다. 다음 명령을 실행하세요:\n"
                "python -m pip install -r requirements-jetson.txt"
            ) from exc
        log_stage("sounddevice imported")
    else:
        log_stage("skipping sounddevice import (--stream-url given)")
    return np, sd


def normalize_device_argument(value: str | None) -> int | str | None:
    if value is None:
        return None
    try:
        return int(value)
    except ValueError:
        return value


@contextmanager
def open_audio_input(
    args: argparse.Namespace,
    np: Any,
    sd: Any,
    device: int | str | None,
    capture_rate: int,
    block_size: int,
    audio_callback: Any,
) -> Any:
    if not args.stream_url:
        if sd is None:
            raise RuntimeError(
                "sounddevice is required when --stream-url is not set"
            )
        with sd.InputStream(
            device=device,
            samplerate=capture_rate,
            channels=1,
            dtype="float32",
            blocksize=block_size,
            callback=audio_callback,
        ):
            yield
        return

    ffmpeg_path = os.getenv("FFMPEG_PATH", "/usr/bin/ffmpeg")
    timeout_option = detect_rtsp_timeout_option(ffmpeg_path)
    if timeout_option is None:
        print(
            "FFmpeg RTSP 읽기 타임아웃 옵션을 찾지 못해 "
            "타임아웃 없이 스트림을 엽니다."
        )
    command = build_audio_command(
        ffmpeg_path,
        args.stream_url,
        capture_rate,
        args.stream_read_timeout_seconds,
        rtsp_timeout_option=timeout_option,
    )

    def handle_pcm_block(data: bytes) -> None:
        chunk = np.frombuffer(data, dtype="<f4").copy().reshape(-1, 1)
        audio_callback(chunk, len(chunk), None, None)

    reader = ReconnectingFfmpegAudio(
        command,
        block_size * 4,
        handle_pcm_block,
        reconnect_initial_seconds=args.reconnect_initial_seconds,
        reconnect_max_seconds=args.reconnect_max_seconds,
        safe_source=redact_stream_url(args.stream_url),
    )
    reader.start()
    try:
        yield
    finally:
        reader.close()


def load_yamnet(model_source: str, cache_dir: str) -> tuple[Any, Any, list[str]]:
    os.environ["TFHUB_CACHE_DIR"] = str(Path(cache_dir).expanduser())
    log_stage(f"TFHUB_CACHE_DIR={os.environ['TFHUB_CACHE_DIR']}")
    log_stage("importing tensorflow")
    try:
        import tensorflow as tf

        log_stage("tensorflow imported, importing tensorflow_hub")
        import tensorflow_hub as hub
    except ImportError as exc:
        raise SystemExit(
            "TensorFlow 패키지를 불러오지 못했습니다. 다음 명령을 실행하세요:\n"
            "python -m pip install -r requirements-jetson.txt"
        ) from exc
    log_stage("tensorflow_hub imported")

    print("YAMNet 모델을 불러오는 중입니다. 첫 실행에서는 모델을 내려받습니다.")
    log_stage(f"hub.load({model_source!r}) starting")
    model = hub.load(model_source)
    log_stage("hub.load finished, reading class map")
    class_map_path = model.class_map_path().numpy()
    if isinstance(class_map_path, bytes):
        class_map_path = class_map_path.decode("utf-8")

    class_names: list[str] = []
    with tf.io.gfile.GFile(class_map_path, "r") as csv_file:
        for row in csv.DictReader(csv_file):
            class_names.append(row["display_name"])
    log_stage(f"class map loaded ({len(class_names)} classes), warming up model")

    warmup_started = time.perf_counter()
    model(tf.zeros(YAMNET_SAMPLE_RATE, dtype=tf.float32))
    print(f"YAMNet 준비 완료 ({time.perf_counter() - warmup_started:.2f}초)")
    log_stage("model warmup complete")
    return tf, model, class_names


def find_laughter_classes(class_names: list[str]) -> list[int]:
    indices = [
        index
        for index, name in enumerate(class_names)
        if any(keyword in name.casefold() for keyword in LAUGHTER_KEYWORDS)
    ]
    if not indices:
        raise RuntimeError("YAMNet 클래스 목록에서 웃음 관련 클래스를 찾지 못했습니다.")
    return indices


def resample(np: Any, waveform: Any, source_rate: int) -> Any:
    waveform = np.asarray(waveform, dtype=np.float32).reshape(-1)
    if source_rate == YAMNET_SAMPLE_RATE:
        return waveform

    output_length = int(round(len(waveform) * YAMNET_SAMPLE_RATE / source_rate))
    source_positions = np.arange(len(waveform), dtype=np.float64)
    target_positions = np.linspace(0, len(waveform) - 1, output_length)
    return np.interp(target_positions, source_positions, waveform).astype(np.float32)


def validate_args(args: argparse.Namespace) -> None:
    if not 0.0 <= args.threshold <= 1.0:
        raise SystemExit("--threshold는 0과 1 사이여야 합니다.")
    if args.consecutive < 1:
        raise SystemExit("--consecutive는 1 이상이어야 합니다.")
    if args.cooldown < 0:
        raise SystemExit("--cooldown은 0 이상이어야 합니다.")
    if args.gain <= 0:
        raise SystemExit("--gain은 0보다 커야 합니다.")
    if args.max_seconds is not None and args.max_seconds <= 0:
        raise SystemExit("--max-seconds는 0보다 커야 합니다.")
    if not 1 <= args.mqtt_port <= 65_535:
        raise SystemExit("--mqtt-port는 1부터 65535 사이여야 합니다.")
    if not args.device_id.strip():
        raise SystemExit("--device-id는 비어 있을 수 없습니다.")

    if args.reconnect_initial_seconds <= 0:
        raise SystemExit("--reconnect-initial-seconds must be positive")
    if args.reconnect_max_seconds < args.reconnect_initial_seconds:
        raise SystemExit(
            "--reconnect-max-seconds must be at least --reconnect-initial-seconds"
        )
    if args.stream_read_timeout_seconds <= 0:
        raise SystemExit("--stream-read-timeout-seconds must be positive")
    if not 0.0 <= args.clap_threshold <= 1.0:
        raise SystemExit("--clap-threshold must be between 0 and 1")
    if args.clap_consecutive < 2:
        raise SystemExit("--clap-consecutive must be at least 2")
    if args.clap_required_onsets < 2:
        raise SystemExit("--clap-required-onsets must be at least 2")
    if args.clap_min_active_seconds < 0:
        raise SystemExit("--clap-min-active-seconds cannot be negative")
    if args.clap_max_gap_seconds <= 0:
        raise SystemExit("--clap-max-gap-seconds must be positive")
    if args.clap_cooldown < 0:
        raise SystemExit("--clap-cooldown cannot be negative")


def write_wav(path: Path, samples: Any, sample_rate: int, np: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = (np.clip(samples, -1.0, 1.0) * 32767.0).astype("<i2")
    temporary = path.with_suffix(path.suffix + ".tmp")
    with wave.open(str(temporary), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm.tobytes())
    temporary.replace(path)


def write_trigger(
    event_dir: Path,
    event_id: str,
    occurred_at: datetime,
    score: float,
    class_name: str,
    clip_seconds: float,
) -> None:
    write_audio_event_trigger(
        event_dir,
        event_id=event_id,
        event_type="LAUGHTER",
        occurred_at=occurred_at,
        confidence=score,
        class_name=class_name,
        clip_seconds=clip_seconds,
    )


def run_detector(args: argparse.Namespace, np: Any, sd: Any) -> None:
    log_stage("run_detector starting")
    validate_args(args)
    if args.clip_seconds <= 0:
        raise SystemExit("--clip-seconds must be positive")
    device = normalize_device_argument(args.device)
    if args.stream_url:
        device_info = {"name": f"shared stream {redact_stream_url(args.stream_url)}"}
        capture_rate = args.sample_rate or YAMNET_SAMPLE_RATE
        log_stage(f"using shared RTSP stream, capture_rate={capture_rate}")
    else:
        log_stage(f"querying local input device via PortAudio: {device!r}")
        try:
            device_info = sd.query_devices(device, "input")
        except Exception as exc:
            raise SystemExit(
                f"입력 장치를 열 수 없습니다: {exc}\n"
                "먼저 --list-devices로 마이크 번호를 확인하세요."
            ) from exc
        capture_rate = args.sample_rate or int(round(device_info["default_samplerate"]))
        log_stage(f"local input device ready, capture_rate={capture_rate}")
    block_size = max(1, int(round(capture_rate * BLOCK_SECONDS)))
    window_size = max(block_size, int(round(capture_rate * WINDOW_SECONDS)))

    log_stage("loading YAMNet model")
    tf, model, class_names = load_yamnet(args.model, args.cache_dir)
    log_stage("YAMNet model loaded")
    laughter_indices = find_laughter_classes(class_names)
    laughter_names = [class_names[index] for index in laughter_indices]
    clap_indices: list[int] = []
    clap_names: list[str] = []
    clap_detector: ConsecutiveClapDetector | None = None
    if args.enable_clap_events:
        clap_indices = find_class_indices(class_names, CLAP_CLASS_KEYWORDS)
        if not clap_indices:
            raise RuntimeError(
                "YAMNet class map does not contain Clapping or Applause"
            )
        clap_names = [class_names[index] for index in clap_indices]
        clap_detector = ConsecutiveClapDetector(
            threshold=args.clap_threshold,
            required_windows=args.clap_consecutive,
            minimum_active_seconds=args.clap_min_active_seconds,
            maximum_gap_seconds=args.clap_max_gap_seconds,
            cooldown_seconds=args.clap_cooldown,
            required_onsets=args.clap_required_onsets,
        )
    audio_queue: queue.Queue[Any] = queue.Queue(maxsize=8)
    mqtt_publisher = None
    if args.mqtt_host and not args.diagnostics_only:
        from mqtt_event_publisher import MqttEventPublisher

        log_stage("initializing MQTT publisher")
        mqtt_publisher = MqttEventPublisher(
            host=args.mqtt_host,
            port=args.mqtt_port,
            device_id=args.device_id,
            username=args.mqtt_username,
            password=args.mqtt_password,
            event_topic=args.mqtt_topic,
        )
        log_stage("MQTT publisher ready")

    def audio_callback(indata: Any, frames: int, timing: Any, status: Any) -> None:
        del frames, timing
        if status:
            print(f"\n오디오 상태: {status}", file=sys.stderr)
        chunk = indata.copy().mean(axis=1)
        try:
            audio_queue.put_nowait(chunk)
        except queue.Full:
            try:
                audio_queue.get_nowait()
            except queue.Empty:
                pass
            audio_queue.put_nowait(chunk)

    print(f"입력 장치: {device_info['name']}")
    print(f"캡처 샘플레이트: {capture_rate} Hz")
    print(f"웃음 관련 클래스: {', '.join(laughter_names)}")
    print(
        f"임계값: {args.threshold:.3f}, 연속 횟수: {args.consecutive}, "
        f"입력 증폭: {args.gain:.2f}배, 점수 집계: {args.score_aggregation}"
    )
    if clap_detector is not None:
        print(
            "Consecutive clap events enabled: "
            f"classes={', '.join(clap_names)} "
            f"threshold={args.clap_threshold:.3f} "
            f"windows={args.clap_consecutive} "
            f"minimumActive={args.clap_min_active_seconds:.2f}s"
        )
    diagnostics_output = None
    if args.diagnostics_jsonl is not None:
        diagnostics_path = args.diagnostics_jsonl.expanduser().resolve()
        diagnostics_path.parent.mkdir(parents=True, exist_ok=True)
        diagnostics_output = diagnostics_path.open(
            "a",
            encoding="utf-8",
            buffering=1,
        )
        print(f"진단 JSONL: {diagnostics_path}")
    if args.diagnostics_only:
        print("진단 전용 모드: 이벤트 파일과 MQTT 메시지를 생성하지 않습니다.")
    print("마이크에 대고 웃어보세요. 종료하려면 Ctrl+C를 누르세요.\n")

    buffer = np.empty(0, dtype=np.float32)
    save_audio_clips = (
        args.event_dir is not None
        and not args.trigger_only
        and not args.diagnostics_only
    )
    history_samples = (
        max(1, int(round(capture_rate * args.clip_seconds)))
        if save_audio_clips
        else 0
    )
    audio_history: deque[Any] = deque()
    audio_history_size = 0
    pending_clips: dict[str, dict[str, Any]] = {}
    positive_streak = 0
    last_alert_at = float("-inf")
    started_at = time.monotonic()

    log_stage("opening audio input (mic or RTSP/ffmpeg)")
    try:
        with open_audio_input(
            args,
            np,
            sd,
            device,
            capture_rate,
            block_size,
            audio_callback,
        ):
            log_stage("audio input opened, waiting for first chunk")
            while True:
                chunk = audio_queue.get()
                if save_audio_clips:
                    audio_history.append(chunk.copy())
                    audio_history_size += len(chunk)
                    while (
                        audio_history
                        and audio_history_size - len(audio_history[0]) >= history_samples
                    ):
                        removed = audio_history.popleft()
                        audio_history_size -= len(removed)

                if save_audio_clips:
                    for event_id, pending in tuple(pending_clips.items()):
                        pending["parts"].append(chunk.copy())
                        pending["post_samples"] += len(chunk)
                        if pending["post_samples"] >= history_samples:
                            samples = np.concatenate(pending["parts"])
                            expected = history_samples * 2
                            if len(samples) > expected:
                                samples = samples[-expected:]
                            write_wav(
                                args.event_dir / f"{event_id}.audio.wav",
                                samples,
                                capture_rate,
                                np,
                            )
                            print(f"\nSaved laughter audio clip: {event_id}.audio.wav")
                            del pending_clips[event_id]
                buffer = np.concatenate((buffer, chunk))
                if len(buffer) < window_size:
                    continue
                buffer = buffer[-window_size:]

                waveform = resample(np, buffer, capture_rate)
                waveform = np.clip(waveform * args.gain, -1.0, 1.0)
                rms = float(np.sqrt(np.mean(np.square(waveform))))

                inference_started = time.perf_counter()
                scores, _, _ = model(tf.convert_to_tensor(waveform, dtype=tf.float32))
                inference_ms = (time.perf_counter() - inference_started) * 1000.0
                scores_np = scores.numpy()

                mean_scores = scores_np.mean(axis=0)
                top_index = int(np.argmax(mean_scores))
                laughter_slice = scores_np[:, laughter_indices]
                score_summary = summarize_laughter_scores(
                    laughter_slice.tolist(),
                    laughter_names,
                    args.score_aggregation,
                )
                laugh_score = score_summary.selected_score
                best_laugh_name = score_summary.selected_class
                now = time.monotonic()
                clap_summary = None
                clap_detection = None
                clap_onset_count = 0
                if clap_detector is not None:
                    clap_slice = scores_np[:, clap_indices]
                    clap_summary = summarize_laughter_scores(
                        clap_slice.tolist(),
                        clap_names,
                        args.score_aggregation,
                    )
                    clap_onset_count = count_impulsive_onsets(
                        waveform.tolist(),
                        YAMNET_SAMPLE_RATE,
                    )
                    clap_detection = clap_detector.observe(
                        clap_summary.selected_score,
                        now,
                        clap_onset_count,
                    )

                if laugh_score >= args.threshold:
                    positive_streak += 1
                else:
                    positive_streak = 0

                print(
                    f"\r현재 소리: {class_names[top_index]:<28} "
                    f"웃음[{args.score_aggregation}]: "
                    f"{laugh_score:.3f} ({best_laugh_name}) "
                    f"RMS: {rms:.4f} 추론: {inference_ms:.0f}ms   ",
                    end="",
                    flush=True,
                )

                should_trigger = (
                    positive_streak >= args.consecutive
                    and now - last_alert_at >= args.cooldown
                )
                if diagnostics_output is not None:
                    diagnostic_record = {
                        "observedAt": datetime.now(timezone.utc)
                        .isoformat(timespec="milliseconds")
                        .replace("+00:00", "Z"),
                        "topClass": class_names[top_index],
                        "topScore": round(
                            float(mean_scores[top_index]),
                            6,
                        ),
                        "laughterMax": round(
                            score_summary.max_score,
                            6,
                        ),
                        "laughterMaxClass": score_summary.max_class,
                        "laughterMean": round(
                            score_summary.mean_score,
                            6,
                        ),
                        "laughterMeanClass": score_summary.mean_class,
                        "laughterP90": round(
                            score_summary.p90_score,
                            6,
                        ),
                        "laughterP90Class": score_summary.p90_class,
                        "selectedAggregation": args.score_aggregation,
                        "selectedScore": round(laugh_score, 6),
                        "selectedClass": best_laugh_name,
                        "threshold": args.threshold,
                        "positiveStreak": positive_streak,
                        "wouldTrigger": should_trigger,
                        "rms": round(rms, 6),
                        "inferenceMs": round(inference_ms, 3),
                    }
                    if clap_summary is not None and clap_detector is not None:
                        diagnostic_record.update(
                            {
                                "clapScore": round(
                                    clap_summary.selected_score,
                                    6,
                                ),
                                "clapClass": clap_summary.selected_class,
                                "clapThreshold": args.clap_threshold,
                                "clapOnsetCount": clap_onset_count,
                                "clapPositiveWindows": (
                                    clap_detection.positive_windows
                                    if clap_detection is not None
                                    else clap_detector.positive_windows
                                ),
                                "clapWouldTrigger": (
                                    clap_detection is not None
                                ),
                            }
                        )
                    diagnostics_output.write(
                        json.dumps(
                            diagnostic_record,
                            ensure_ascii=False,
                            separators=(",", ":"),
                        )
                        + "\n"
                    )

                if should_trigger:
                    print(
                        f"\n웃음 {'진단 판정' if args.diagnostics_only else '감지'}! "
                        f"점수={laugh_score:.3f} "
                        f"종류={best_laugh_name}"
                    )
                    positive_streak = 0
                    last_alert_at = now
                    event_id = None
                    if args.event_dir is not None and not args.diagnostics_only:
                        event_id = str(uuid.uuid4())
                        occurred_at = datetime.now(timezone.utc)
                        if save_audio_clips:
                            pre_audio = np.concatenate(tuple(audio_history))
                            if len(pre_audio) > history_samples:
                                pre_audio = pre_audio[-history_samples:]
                            pending_clips[event_id] = {
                                "parts": [pre_audio.copy()],
                                "post_samples": 0,
                            }
                        write_trigger(
                            args.event_dir,
                            event_id,
                            occurred_at,
                            laugh_score,
                            best_laugh_name,
                            args.clip_seconds,
                        )
                        print(f"Local laughter event: {event_id}")
                    if mqtt_publisher is not None:
                        try:
                            mqtt_publisher.publish_laughter(
                                event_id=event_id,
                                score=laugh_score,
                                class_name=best_laugh_name,
                                threshold=args.threshold,
                                consecutive=args.consecutive,
                                monotonic_ns=time.monotonic_ns(),
                            )
                        except Exception as exc:
                            print(
                                f"MQTT 이벤트 발행 실패: {exc}",
                                file=sys.stderr,
                            )

                if clap_detection is not None and clap_summary is not None:
                    print(
                        "\nConsecutive clap detected! "
                        f"score={clap_detection.score:.3f} "
                        f"class={clap_summary.selected_class} "
                        f"windows={clap_detection.positive_windows} "
                        f"active={clap_detection.active_seconds:.2f}s"
                    )
                    clap_event_id = None
                    if args.event_dir is not None and not args.diagnostics_only:
                        clap_event_id = str(uuid.uuid4())
                        occurred_at = datetime.now(timezone.utc)
                        if save_audio_clips:
                            pre_audio = np.concatenate(tuple(audio_history))
                            if len(pre_audio) > history_samples:
                                pre_audio = pre_audio[-history_samples:]
                            pending_clips[clap_event_id] = {
                                "parts": [pre_audio.copy()],
                                "post_samples": 0,
                            }
                        write_audio_event_trigger(
                            args.event_dir,
                            event_id=clap_event_id,
                            event_type="CLAP",
                            occurred_at=occurred_at,
                            confidence=clap_detection.score,
                            class_name=clap_summary.selected_class,
                            clip_seconds=args.clip_seconds,
                            metadata={
                                "positiveWindows": (
                                    clap_detection.positive_windows
                                ),
                                "onsetCount": clap_detection.onset_count,
                                "activeSeconds": round(
                                    clap_detection.active_seconds,
                                    3,
                                ),
                                "scoreAggregation": args.score_aggregation,
                            },
                        )
                        print(f"Local clap event: {clap_event_id}")
                    if mqtt_publisher is not None:
                        try:
                            mqtt_publisher.publish_event(
                                event_type="CLAP",
                                event_id=clap_event_id,
                                score=clap_detection.score,
                                class_name=clap_summary.selected_class,
                                threshold=args.clap_threshold,
                                consecutive=args.clap_consecutive,
                                monotonic_ns=time.monotonic_ns(),
                                metadata={
                                    "activeSeconds": round(
                                        clap_detection.active_seconds,
                                        3,
                                    ),
                                    "onsetCount": clap_detection.onset_count,
                                },
                            )
                        except Exception as exc:
                            print(
                                f"MQTT clap event publish failed: {exc}",
                                file=sys.stderr,
                            )

                if args.max_seconds is not None and now - started_at >= args.max_seconds:
                    print("\n지정한 실행 시간이 지나 감지를 종료합니다.")
                    break
    except KeyboardInterrupt:
        print("\n감지를 종료했습니다.")
    except Exception as exc:
        raise SystemExit(
            f"마이크 스트림 실행 중 오류가 발생했습니다: {exc}\n"
            "--list-devices로 장치를 확인하고 --device 번호를 지정해 보세요."
        ) from exc
    finally:
        if mqtt_publisher is not None:
            mqtt_publisher.close()
        if diagnostics_output is not None:
            diagnostics_output.close()


def main() -> None:
    log_stage("process started, parsing arguments")
    args = parse_args()
    log_stage(f"arguments parsed (stream_url={'set' if args.stream_url else 'unset'})")
    np, sd = require_audio_packages(
        need_sounddevice=bool(args.list_devices or not args.stream_url)
    )

    if args.list_devices:
        print(sd.query_devices())
        return

    run_detector(args, np, sd)


if __name__ == "__main__":
    main()
