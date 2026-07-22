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
import subprocess
import sys
import threading
import time
import uuid
import wave
from pathlib import Path
from typing import Any

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
        "--stream-url",
        default=os.getenv("YAMNET_SOURCE_URL"),
        help="Local shared media URL. When set, the microphone is decoded by FFmpeg.",
    )
    parser.add_argument(
        "--clip-seconds",
        type=float,
        default=5.0,
        help="Seconds to retain before and after laughter (default: 5).",
    )
    return parser.parse_args()


def require_audio_packages() -> tuple[Any, Any]:
    try:
        import numpy as np
        import sounddevice as sd
    except ImportError as exc:
        raise SystemExit(
            "오디오 패키지를 불러오지 못했습니다. 다음 명령을 실행하세요:\n"
            "python -m pip install -r requirements-jetson.txt"
        ) from exc
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

    command = [
        os.getenv("FFMPEG_PATH", "/usr/bin/ffmpeg"),
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "error",
        "-fflags",
        "nobuffer",
        "-i",
        args.stream_url,
        "-map",
        "0:a:0",
        "-vn",
        "-ac",
        "1",
        "-ar",
        str(capture_rate),
        "-f",
        "f32le",
        "pipe:1",
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if process.stdout is None:
        process.kill()
        raise RuntimeError("FFmpeg audio pipe was not created")
    stopped = threading.Event()

    def read_audio() -> None:
        block_bytes = block_size * 4
        buffered = bytearray()
        while not stopped.is_set():
            data = process.stdout.read(block_bytes - len(buffered))
            if not data:
                if not stopped.is_set():
                    print(
                        f"Shared audio decoder stopped with status {process.poll()}",
                        file=sys.stderr,
                    )
                return
            buffered.extend(data)
            if len(buffered) < block_bytes:
                continue
            chunk = np.frombuffer(buffered, dtype="<f4").copy().reshape(-1, 1)
            buffered.clear()
            audio_callback(chunk, len(chunk), None, None)

    reader = threading.Thread(target=read_audio, name="shared-audio-reader", daemon=True)
    reader.start()
    try:
        yield
    finally:
        stopped.set()
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1)
        reader.join(timeout=1)


def load_yamnet(model_source: str, cache_dir: str) -> tuple[Any, Any, list[str]]:
    os.environ["TFHUB_CACHE_DIR"] = str(Path(cache_dir).expanduser())
    try:
        import tensorflow as tf
        import tensorflow_hub as hub
    except ImportError as exc:
        raise SystemExit(
            "TensorFlow 패키지를 불러오지 못했습니다. 다음 명령을 실행하세요:\n"
            "python -m pip install -r requirements-jetson.txt"
        ) from exc

    print("YAMNet 모델을 불러오는 중입니다. 첫 실행에서는 모델을 내려받습니다.")
    model = hub.load(model_source)
    class_map_path = model.class_map_path().numpy()
    if isinstance(class_map_path, bytes):
        class_map_path = class_map_path.decode("utf-8")

    class_names: list[str] = []
    with tf.io.gfile.GFile(class_map_path, "r") as csv_file:
        for row in csv.DictReader(csv_file):
            class_names.append(row["display_name"])

    warmup_started = time.perf_counter()
    model(tf.zeros(YAMNET_SAMPLE_RATE, dtype=tf.float32))
    print(f"YAMNet 준비 완료 ({time.perf_counter() - warmup_started:.2f}초)")
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
    event_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "schemaVersion": "1.0",
        "eventId": event_id,
        "type": "LAUGHTER",
        "occurredAt": occurred_at.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "confidence": round(score, 6),
        "className": class_name,
        "preSeconds": clip_seconds,
        "postSeconds": clip_seconds,
    }
    destination = event_dir / f"{event_id}.trigger.json"
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    temporary.replace(destination)


def run_detector(args: argparse.Namespace, np: Any, sd: Any) -> None:
    validate_args(args)
    if args.clip_seconds <= 0:
        raise SystemExit("--clip-seconds must be positive")
    device = normalize_device_argument(args.device)
    if args.stream_url:
        device_info = {"name": f"shared stream {args.stream_url}"}
        capture_rate = args.sample_rate or YAMNET_SAMPLE_RATE
    else:
        try:
            device_info = sd.query_devices(device, "input")
        except Exception as exc:
            raise SystemExit(
                f"입력 장치를 열 수 없습니다: {exc}\n"
                "먼저 --list-devices로 마이크 번호를 확인하세요."
            ) from exc
        capture_rate = args.sample_rate or int(round(device_info["default_samplerate"]))
    block_size = max(1, int(round(capture_rate * BLOCK_SECONDS)))
    window_size = max(block_size, int(round(capture_rate * WINDOW_SECONDS)))

    tf, model, class_names = load_yamnet(args.model, args.cache_dir)
    laughter_indices = find_laughter_classes(class_names)
    laughter_names = [class_names[index] for index in laughter_indices]
    audio_queue: queue.Queue[Any] = queue.Queue(maxsize=8)
    mqtt_publisher = None
    if args.mqtt_host:
        from mqtt_event_publisher import MqttEventPublisher

        mqtt_publisher = MqttEventPublisher(
            host=args.mqtt_host,
            port=args.mqtt_port,
            device_id=args.device_id,
            username=args.mqtt_username,
            password=args.mqtt_password,
            event_topic=args.mqtt_topic,
        )

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
        f"임계값: {args.threshold:.2f}, 연속 횟수: {args.consecutive}, "
        f"입력 증폭: {args.gain:.2f}배"
    )
    print("마이크에 대고 웃어보세요. 종료하려면 Ctrl+C를 누르세요.\n")

    buffer = np.empty(0, dtype=np.float32)
    history_samples = max(1, int(round(capture_rate * args.clip_seconds)))
    audio_history: deque[Any] = deque()
    audio_history_size = 0
    pending_clips: dict[str, dict[str, Any]] = {}
    positive_streak = 0
    last_alert_at = float("-inf")
    started_at = time.monotonic()

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
            while True:
                chunk = audio_queue.get()
                audio_history.append(chunk.copy())
                audio_history_size += len(chunk)
                while audio_history and audio_history_size - len(audio_history[0]) >= history_samples:
                    removed = audio_history.popleft()
                    audio_history_size -= len(removed)

                if args.event_dir is not None:
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
                per_class_max = np.max(laughter_slice, axis=0)
                best_laugh_offset = int(np.argmax(per_class_max))
                laugh_score = float(per_class_max[best_laugh_offset])
                best_laugh_name = laughter_names[best_laugh_offset]

                if laugh_score >= args.threshold:
                    positive_streak += 1
                else:
                    positive_streak = 0

                print(
                    f"\r현재 소리: {class_names[top_index]:<28} "
                    f"웃음: {laugh_score:.3f} ({best_laugh_name}) "
                    f"RMS: {rms:.4f} 추론: {inference_ms:.0f}ms   ",
                    end="",
                    flush=True,
                )

                now = time.monotonic()
                if (
                    positive_streak >= args.consecutive
                    and now - last_alert_at >= args.cooldown
                ):
                    print(
                        f"\n웃음 감지! 점수={laugh_score:.3f} "
                        f"종류={best_laugh_name}"
                    )
                    positive_streak = 0
                    last_alert_at = now
                    if args.event_dir is not None:
                        event_id = str(uuid.uuid4())
                        occurred_at = datetime.now(timezone.utc)
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


def main() -> None:
    args = parse_args()
    np, sd = require_audio_packages()

    if args.list_devices:
        print(sd.query_devices())
        return

    run_detector(args, np, sd)


if __name__ == "__main__":
    main()
