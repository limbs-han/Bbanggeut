"""녹화 파일에서 벤치마크용 클립을 잘라낸다.

홈캠 녹음 정답지를 만들 때 쓴다. 시작 시각을 주면 그 지점부터 30초를 16kHz
모노 wav로 뽑고, 정답을 적을 빈 텍스트 파일을 짝으로 만든다.

    python prepare_clips.py --input rec.mp4 --at 0:15 --at 2:30 --at 5:00 \
        --out dataset/homecam --prefix homecam

**ffmpeg를 설치하지 않아도 된다** — PyAV가 wheel에 ffmpeg를 담고 있다.
mp4·mkv·m4a·wav 등 컨테이너를 가리지 않는다.

시작 시각은 `mm:ss`, `hh:mm:ss`, 초(정수·소수) 다 받는다.

자른 뒤에 할 일은 `05-STT모델가이드.md` 4부 2번에 있다 — 표기 규칙을 지켜야
CER이 모델 성능이 아니라 표기 차이를 재게 되는 것을 막는다.
"""

from __future__ import annotations

import argparse
import io
from pathlib import Path

import av
import numpy as np
import soundfile as sf

SAMPLE_RATE = 16_000


def parse_time(value: str) -> float:
    """`mm:ss`, `hh:mm:ss`, 초를 모두 초 단위로 바꾼다."""
    parts = value.split(":")
    if len(parts) > 3:
        raise argparse.ArgumentTypeError(f"시각 형식을 알 수 없습니다: {value}")
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + float(part)
    return seconds


def decode(path: Path) -> np.ndarray:
    """오디오 트랙을 16kHz 모노 float32로 만든다. 영상 파일도 받는다."""
    with av.open(str(path)) as container:
        if not container.streams.audio:
            raise SystemExit(f"오디오 트랙이 없습니다: {path}")
        stream = container.streams.audio[0]
        resampler = av.AudioResampler(format="fltp", layout="mono", rate=SAMPLE_RATE)
        chunks: list[np.ndarray] = []
        for frame in container.decode(stream):
            for resampled in resampler.resample(frame):
                chunks.append(resampled.to_ndarray().reshape(-1))
        for resampled in resampler.resample(None):
            chunks.append(resampled.to_ndarray().reshape(-1))
    if not chunks:
        raise SystemExit(f"오디오를 디코딩하지 못했습니다: {path}")
    return np.concatenate(chunks).astype(np.float32)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="녹화 파일(영상/음성)")
    parser.add_argument(
        "--at",
        type=parse_time,
        action="append",
        required=True,
        dest="starts",
        help="클립 시작 시각. 여러 번 줄 수 있다 (mm:ss / hh:mm:ss / 초)",
    )
    parser.add_argument("--duration", type=float, default=30.0, help="클립 길이(초)")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--prefix", default="homecam", help="파일 이름 접두사")
    args = parser.parse_args()

    if not args.input.exists():
        raise SystemExit(f"입력 파일이 없습니다: {args.input}")

    audio = decode(args.input)
    total = len(audio) / SAMPLE_RATE
    print(f"[입력] {args.input.name} — 오디오 {total / 60:.1f}분")

    args.out.mkdir(parents=True, exist_ok=True)
    # 이어붙여 만들 때 앞선 실행의 클립이 섞이면 몇 개로 측정한 것인지 알 수 없다.
    existing = sorted(args.out.glob(f"{args.prefix}*"))
    if existing:
        print(f"[주의] {args.out}에 {len(existing)}개 파일이 이미 있습니다. 덮어씁니다.")

    written = 0
    for index, start in enumerate(sorted(args.starts), 1):
        if start >= total:
            print(f"[건너뜀] {start:.1f}초는 파일 길이({total:.1f}초)를 넘습니다")
            continue
        begin = int(start * SAMPLE_RATE)
        end = min(int((start + args.duration) * SAMPLE_RATE), len(audio))
        clip = audio[begin:end]
        seconds = len(clip) / SAMPLE_RATE
        if seconds < 1.0:
            print(f"[건너뜀] {start:.1f}초 지점 클립이 {seconds:.1f}초뿐입니다")
            continue

        stem = f"{args.prefix}{index:03d}"
        sf.write(args.out / f"{stem}.wav", clip, SAMPLE_RATE, subtype="PCM_16")
        # 정답은 사람이 적는다. 빈 파일을 만들어 짝을 맞춰 둔다 —
        # run_benchmark.py는 정답 파일이 없으면 즉시 멈춘다.
        (args.out / f"{stem}_original.txt").write_text("", encoding="utf-8")
        written += 1
        print(f"  {stem}.wav  {start:.0f}초부터 {seconds:.1f}초")

    if not written:
        raise SystemExit("클립을 하나도 만들지 못했습니다.")

    print(f"\n{written}개 클립을 {args.out}에 만들었습니다.")
    print("\n이제 각 `_original.txt`에 들린 대로 정답을 적으세요. 표기 규칙:")
    print("  - 말한 낱말을 표준 표기로. 발음을 흉내내지 않고, 없는 말을 채우지도 않는다")
    print("  - 문장부호 없이, 어절 띄어쓰기만")
    print("  - 알아들을 수 없는 구간은 [불명]")
    print("  - UTF-8로 저장 (메모장은 'UTF-8' 선택)")
    print(f"\n다 적었으면: python run_benchmark.py --dir {args.out}")
    print("정답 총량이 500자 이상이어야 순위를 믿을 수 있습니다.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
