"""한국어 STT 모델을 같은 조건에서 비교한다.

**같은 조건이 이 스크립트의 존재 이유다.** 세 모델은 런타임이 서로 다르지만
(whisper 2개는 transformers, SenseVoice는 funasr) 아래를 전부 공유한다.

  - 같은 오디오: 파일을 한 번만 디코딩해 16kHz 모노 float32 numpy로 만들고
    그 배열을 세 모델에 그대로 넘긴다. 모델이 파일을 각자 읽게 하면
    디코더·리샘플러가 갈려서 입력이 달라진다.
  - 같은 정밀도: fp32. fp16으로 맞추려 하면 funasr 쪽 경로가 불확실해서
    whisper만 fp16이 되고 조건이 깨진다.
  - 같은 정규화와 같은 CER 계산: `normalize()` 하나를 통과한다.
  - 같은 GPU, 순차 실행: 동시에 올리지 않는다(VRAM 6GB).

양자화는 하지 않는다. 모델마다 양자화 방식이 달라(q5_0 대 int8) 변수를
더하는 일이 되고, 그러면 무엇 때문에 순위가 갈렸는지 알 수 없다.

돌리는 법:

    python run_benchmark.py --dir dataset/zeroth
    python run_benchmark.py --audio <파일.m4a>

정답은 오디오와 같은 폴더의 `<이름>_original.txt`에서 읽는다.
"""

from __future__ import annotations

import argparse
import re
import sys
import time
import unicodedata
from pathlib import Path

import av
import jiwer
import numpy as np
import torch

SAMPLE_RATE = 16_000
AUDIO_SUFFIXES = {".wav", ".flac", ".m4a", ".mp3", ".ogg", ".bin"}

# 추론 스레드. 앱과 같은 값으로 맞춘다(whisper_transcriber.dart의 threads=6) —
# 양자화 CPU 추론 시간을 폰 시간의 대리 지표로 쓰려면 같아야 한다.
THREADS = 6

HERE = Path(__file__).resolve().parent
LOCAL_MODELS = HERE / "models"
# 앱이 실제로 담아 배포하는 파일을 그대로 쓴다. 따로 변환하면 앱과 다른 것을 재게 된다.
APP_ASSET = HERE.parent.parent / "frontend" / "assets" / "models" / "ggml-small-ko-q5_1.bin"

# (표시 이름, 런타임, 모델 ID 또는 파일 경로)
#
# 위 3개는 fp32 GPU — 양자화 손실이 없는 "모델 자체의 실력"이다.
# 아래 3개는 실제 배포 형태(양자화 + CPU) — 앱에서 무엇을 얻는지다.
# 두 묶음의 추론 시간은 서로 비교할 수 없다(GPU 대 CPU). CER은 비교할 수 있다.
MODELS = [
    ("small-ko fp32 (transformers)", "transformers", "SungBeom/whisper-small-ko"),
    ("turbo fp32 (transformers)", "transformers", "openai/whisper-large-v3-turbo"),
    ("SenseVoice fp32 (funasr)", "funasr", "FunAudioLLM/SenseVoiceSmall"),
    # 앱이 지금 배포하는 것과, 교체 전에 쓰던 것(회귀 비교용).
    # q5_0-rebuilt는 앱에 있던 q5_0과 SHA256이 같은 파일이다.
    ("small-ko q5_1 (앱 에셋)", "whispercpp", str(APP_ASSET)),
    ("small-ko q5_0 (교체 전)", "whispercpp", str(LOCAL_MODELS / "ggml-small-ko-q5_0-rebuilt.bin")),
    # q8_0을 다시 넣었다. zeroth에서 q5_1과 같은 2.9%라 볼 것이 없다고 판단했지만,
    # 잡음 조건에서 small-ko의 양자화 손실이 크게 드러났다(meeting: fp32 10.3% →
    # q5_1 16.3%, +6.0%p). SenseVoice int8은 +1.7%p뿐이라 배포 형태에서 뒤집힌다.
    # **양자화 손실은 조건마다 다르므로** 8비트를 잡음 조건에서 재봐야 한다.
    ("small-ko q8_0 (whisper.cpp)", "whispercpp", str(LOCAL_MODELS / "ggml-small-ko-q8_0.bin")),
    ("SenseVoice int8 (sherpa-onnx)", "sherpa", str(LOCAL_MODELS / "sensevoice-model.int8.onnx")),
]

# 상시 측정에서 뺀 항목 — 진단이 끝났다. 파일은 models/에 그대로 있으므로
# 아래 줄을 되살리고 --only로 언제든 재현된다.
#
#   ("turbo fp16 (whisper.cpp)", ... / "ggml-large-v3-turbo.bin"),
#   ("turbo q5_0 (whisper.cpp)", ... / "ggml-large-v3-turbo-q5_0.bin"),
#   ("small-ko fp16 (whisper.cpp)", ... / "ggml-small-ko-f16.bin"),
#   ("small-ko q8_0 (whisper.cpp)", ... / "ggml-small-ko-q8_0.bin"),
#   ("small-ko q4_0 (whisper.cpp)", ... / "ggml-small-ko-q4_0.bin"),
#
# ## 이것들이 답한 것 (zeroth, 정답 1361자)
#
# 1) 런타임 차이는 없다. turbo가 fp32(transformers) 1.4%, fp16(whisper.cpp)
#    1.4%로 같았다. whisper.cpp가 부정확한 것이 아니다.
# 2) q5_0 양자화는 큰 모델에서 무해하다. turbo fp16 1.4% → q5_0 1.5%.
# 3) 앱 에셋 파일은 손상되지 않았다. PC에서 다시 양자화한 결과가 SHA256까지
#    같았다 — 안드로이드 크로스컴파일과 adb 전송 모두 정확했다.
# 4) **q5_0 포맷 자체가 이 모델에서 깨진다.** small-ko의 양자화 사다리:
#       fp16 2.9% / q8_0 2.9% / q5_1 2.9% / q5_0 10.7% / q4_0 3.4%
#    정밀도가 더 낮은 q4_0이 q5_0을 3배 이긴다. 비트 수로도 대칭성으로도
#    설명되지 않는다(q4_0도 대칭이다) — q5_0의 5비트 패킹이 병리적이다.
#
# 5) **q4_0은 낭독에서만 좋다.** zeroth 3.4%로 q5_0을 3배 이기지만 8kHz
#    전화망에서 41.0%로 가장 나쁘다. 정보가 적은 입력에서 4비트가 먼저
#    무너진다 — "용량 줄이며 정확도 얻기"는 쉬운 조건에서만 성립한다.
#
# **결론: 앱 에셋을 q5_0 → q5_1로 교체했다**(2026-07-29). 세 조건 모두에서
# 좋거나 같고 추론 시간은 동일하다. q8_0과 fp16은 q5_1과 같은 2.9%인데
# 크기만 크므로 볼 것이 없다.

# --- 정규화 -----------------------------------------------------------------
# CER이 모델 성능이 아니라 표기 방식의 차이를 재는 것을 막는다.

# 자막 정답의 타임스탬프 줄. 문장부호를 지우기 전에 먼저 없애야 한다 —
# 나중에 지우면 "0000"이 본문에 섞인다.
_STAMP = re.compile(r"^\s*\d{1,2}:\d{2}(?::\d{2})?\s*$", re.MULTILINE)

# AI Hub 전사의 이중 표기에 대한 **안전망**이다. 정상 경로에서는
# `fetch_dataset.py`가 추출할 때 이미 풀어서 저장한다 — **데이터셋마다 표기
# 순서가 반대**이기 때문이다.
#
#   phone(571)   : (12월)/(십 이 월)        → 앞이 철자
#   meeting(464) : (아홉 건의)/(9건의)      → 뒤가 철자
#
# 그 분기를 여기 두면 정답과 가설이 같은 함수를 통과한다는 원칙이 깨진다.
# 여기서는 혹시 남은 것을 앞쪽으로 풀어 CER이 슬래시 때문에 부풀지 않게만 한다.
_DUAL = re.compile(r"\(([^()]*)\)/\([^()]*\)")

# AI Hub 회의 음성(464)의 비식별화·비언어 표기.
# @이름1 @정당2 @상호명3 @전화번호1 @주소1 (비식별화), @웃음 @목청 @노래 (비언어).
# 모델이 맞출 수 없으므로 제거한다. @백신처럼 실제 낱말인 경우도 있지만
# 합쳐 0.1% 미만이라 토큰째 지운다.
_ANON = re.compile(r"@\S+")

# AI Hub 잡음·간투어 태그. b/=숨소리 n/=잡음 l/=웃음 o/=간투어 u/=불분명.
# 공백 뒤에만 오므로 그 조건을 붙인다 — 안 붙이면 영문 낱말을 잘라먹는다.
_AIHUB_TAG = re.compile(r"(?:^|\s)[bnlou]/")

# SenseVoice가 붙이는 감정·이벤트·언어 태그(<|HAPPY|>, <|Laughter|>),
# 정답지의 [불명], AI Hub의 (()) — 알아들을 수 없는 구간 표기다.
# 안 지우면 CER이 태그 길이만큼 부풀어 무조건 진다.
#
# `/(bgm)` `/(noise)`는 회의 음성(464)의 배경음 표기다. 괄호와 슬래시만
# 지우면 **`bgm`·`noise`라는 낱말이 정답에 남는다** — 잡음 발화만 골라 뽑은
# meeting에서 그것이 정답의 8.7%를 차지했다. 모델이 낼 수 없는 글자다.
_TAG = re.compile(r"<\|[^|]*\|>|\[[^\]]*\]|\(\(\)\)|/\([^)]*\)")

# 공백과 문장부호 전부. 한글·영문·숫자만 남는다(\w는 한글을 포함한다).
_PUNCT = re.compile(r"[^\w]|_", re.UNICODE)


def normalize(text: str) -> str:
    """CER을 재기 직전에 정답과 가설 양쪽에 똑같이 적용한다.

    순서가 중요하다 — 이중 표기를 먼저 풀어야 슬래시가 태그 패턴과
    충돌하지 않고, 타임스탬프를 먼저 지워야 숫자가 본문에 섞이지 않는다.
    """
    text = _DUAL.sub(r"\1", text)
    text = _ANON.sub(" ", text)
    text = _AIHUB_TAG.sub(" ", text)
    text = _STAMP.sub("", text)
    text = _TAG.sub("", text)
    return _PUNCT.sub("", text)


def to_jamo(text: str) -> str:
    """한글 음절을 자모로 분해한다 — 발음이 비슷한 오류를 부분 점수로 반영한다.

    음절 단위 CER은 자모 하나만 달라도 음절 전체를 오류로 센다. `것`과 `거`가
    완전히 다른 것으로 잡히는데, 실제로는 종성 하나 차이다. NFD로 분해하면
    `것`(ㄱㅓㅅ) 대 `거`(ㄱㅓ)가 3분의 1 오류가 된다.

    **CER과 절대값을 비교하면 안 된다** — 분모(자모 수)가 음절 수의 2~3배라
    항상 낮게 나온다. 모델 간 상대 비교에만 쓴다.

    한국어 ASR 평가에서 쓰이는 지표이므로 특정 데이터셋에 맞춘 조정이 아니다.
    """
    return unicodedata.normalize("NFD", text)


# --- 입력 -------------------------------------------------------------------


def decode_audio(path: Path) -> np.ndarray:
    """오디오를 16kHz 모노 float32로 만든다.

    PyAV를 쓰는 이유: ffmpeg 바이너리를 시스템에 설치하지 않아도 m4a를 읽는다
    (wheel에 들어 있다). transformers의 오디오 로더는 ffmpeg 실행 파일을
    찾으므로 이 환경에서는 쓸 수 없다.
    """
    with av.open(str(path)) as container:
        stream = container.streams.audio[0]
        resampler = av.AudioResampler(format="fltp", layout="mono", rate=SAMPLE_RATE)
        chunks: list[np.ndarray] = []
        for frame in container.decode(stream):
            for resampled in resampler.resample(frame):
                chunks.append(resampled.to_ndarray().reshape(-1))
        # 리샘플러 내부 버퍼를 비운다. 안 하면 끝부분 몇 ms가 잘린다.
        for resampled in resampler.resample(None):
            chunks.append(resampled.to_ndarray().reshape(-1))

    if not chunks:
        raise SystemExit(f"오디오를 디코딩하지 못했습니다: {path}")
    return np.concatenate(chunks).astype(np.float32)


def read_truth(audio: Path) -> str:
    """정답 파일을 읽는다. UTF-16(BOM 있음)과 UTF-8을 모두 받는다.

    **UTF-16은 BOM으로만 판별한다.** 인코딩을 순서대로 시도하면 안 된다 —
    UTF-8 한글 파일이 우연히 짝수 바이트면 UTF-16 디코딩이 예외 없이
    "성공"하고 한자 쓰레기를 돌려준다. NUL 문자로 걸러지지도 않는다.
    실제로 이걸 못 걸러서 CER 57%를 모델 탓으로 오판했다.
    """
    truth = audio.with_name(f"{audio.stem}_original.txt")
    if not truth.exists():
        # 조용히 건너뛰면 정답 없는 클립을 0% CER로 착각한다. 즉시 멈춘다.
        raise SystemExit(f"정답 파일이 없습니다: {truth}")

    raw = truth.read_bytes()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        return raw.decode("utf-16")
    for encoding in ("utf-8-sig", "utf-8", "cp949"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    raise SystemExit(f"정답 파일의 인코딩을 알 수 없습니다: {truth}")


def collect_clips(paths: list[Path], directories: list[Path]) -> list[tuple[Path, np.ndarray, str]]:
    files = list(paths)
    for directory in directories:
        if not directory.is_dir():
            raise SystemExit(f"폴더가 없습니다: {directory}")
        # sorted: 실행 순서를 고정한다. 순서가 달라지면 결과를 비교할 수 없다.
        files.extend(sorted(p for p in directory.iterdir() if p.suffix.lower() in AUDIO_SUFFIXES))

    clips = []
    for path in files:
        if not path.exists():
            raise SystemExit(f"오디오 파일이 없습니다: {path}")
        try:
            audio = decode_audio(path)
        except av.FFmpegError as error:
            # 공개 데이터셋에는 깨진 파일이 섞여 있다. 건너뛰되 반드시
            # 알린다 — 조용히 빠지면 몇 개로 측정한 것인지 알 수 없다.
            print(f"[건너뜀] {path.name}: 디코딩 실패 ({error})", file=sys.stderr)
            continue
        clips.append((path, audio, read_truth(path)))
    if not clips:
        raise SystemExit("클립을 하나도 찾지 못했습니다.")
    return clips


# --- 추론 -------------------------------------------------------------------
# 런너는 클립 전체를 받는다. 클립마다 모델을 다시 로드하면 40클립에 40번
# 로드하게 된다 — 모델 로딩이 추론보다 훨씬 오래 걸린다.


def _payload(audio: np.ndarray) -> dict:
    """추론 호출마다 새로 만든다.

    transformers 파이프라인은 넘긴 dict에서 키를 pop한다 — 같은 dict를 두 번
    쓰면 두 번째 호출이 "raw 키가 없다"며 죽는다. 재시도 경로에서 실제로 겪었다.
    """
    return {"raw": audio, "sampling_rate": SAMPLE_RATE}


def transcribe_transformers(model_id: str, audios: list[np.ndarray]) -> list[tuple[str, float]]:
    from transformers import pipeline

    # 모델 로딩(과 첫 실행의 다운로드)은 시간 측정 밖에 둔다. 안 그러면
    # 다운로드 시간이 추론 시간으로 잡힌다 — 273초로 한 번 오판했다.
    pipe = pipeline(
        "automatic-speech-recognition",
        model=model_id,
        dtype=torch.float32,
        device=0 if torch.cuda.is_available() else -1,
    )

    # 한국어 전용으로 미세조정된 모델은 generation config가 낡아서 language
    # 인자를 거부한다(SungBeom/whisper-small-ko가 그렇다). 그 모델은 한국어
    # 전용이므로 언어를 강제할 필요가 없다 — 제작자가 정한 기본값으로 돌린다.
    # 첫 클립에서 한 번 판단하고 나머지 클립에 그대로 적용한다.
    def run(audio: np.ndarray, korean: bool) -> dict:
        """30초 초과 오디오를 처리하는 세 경로를 순서대로 시도한다.

        transformers는 30초를 넘으면 long-form 생성으로 넘어가면서 타임스탬프
        토큰 예측을 요구한다. 그런데 `SungBeom/whisper-small-ko`는 generation
        config가 낡아서 **타임스탬프도 못 낸다**(`language` 인자를 거부하는 것과
        같은 원인). 그 모델은 30초 청킹으로 우회한다.

        데이터셋 클립은 전부 30초 미만이라 이 경로가 드러나지 않았고,
        `--audio`로 75초 녹음을 넣었을 때 처음 터졌다. whisper.cpp 쪽은 자체
        청킹이라 이 문제가 없다.
        """
        kwargs = {"generate_kwargs": {"language": "ko", "task": "transcribe"}} if korean else {}
        long_form = len(audio) > 30 * SAMPLE_RATE
        if not long_form:
            return pipe(_payload(audio), **kwargs)
        try:
            return pipe(_payload(audio), return_timestamps=True, **kwargs)
        except ValueError as error:
            if "timestamp" not in str(error).lower():
                raise
            print("    (타임스탬프 미지원 — 30초 청킹으로 우회)", file=sys.stderr)
            return pipe(_payload(audio), chunk_length_s=30, **kwargs)

    force_korean = True
    results = []
    for audio in audios:
        started = time.perf_counter()
        if force_korean:
            try:
                out = run(audio, korean=True)
            except ValueError as error:
                print(f"    (language 인자 거부 — 기본값으로 재시도)", file=sys.stderr)
                print(f"      {error}", file=sys.stderr)
                force_korean = False
                started = time.perf_counter()
                out = run(audio, korean=False)
        else:
            out = run(audio, korean=False)
        results.append((out["text"], time.perf_counter() - started))

    del pipe
    torch.cuda.empty_cache()
    return results


def transcribe_funasr(model_id: str, audios: list[np.ndarray]) -> list[tuple[str, float]]:
    from funasr import AutoModel

    model = AutoModel(
        model=model_id,
        hub="hf",  # 기본값은 modelscope다. HuggingFace 쪽을 쓴다.
        device="cuda:0" if torch.cuda.is_available() else "cpu",
        disable_update=True,
    )

    results = []
    for audio in audios:
        started = time.perf_counter()
        # use_itn=False: 역정규화를 끈다. 켜면 숫자·문장부호를 넣어서
        # 정답 표기 규칙(숫자는 한글, 문장부호 없음)과 어긋난다.
        out = model.generate(input=audio, fs=SAMPLE_RATE, language="ko", use_itn=False)
        results.append((out[0]["text"], time.perf_counter() - started))

    del model
    torch.cuda.empty_cache()
    return results


def transcribe_whispercpp(model_path: str, audios: list[np.ndarray]) -> list[tuple[str, float]]:
    """양자화된 GGML 모델을 whisper.cpp로 돌린다 — 앱과 같은 런타임이다.

    양자화 손실은 이 경로에서만 나타난다. transformers의 fp32 추론으로는
    q5_0이 정확도를 얼마나 깎는지 알 수 없다.
    """
    from pywhispercpp.model import Model

    if not Path(model_path).exists():
        raise FileNotFoundError(
            f"{model_path}이 없습니다. 만드는 절차는 자료/docs/사람이 읽을 문서/06-STT모델가이드.md 참조."
        )

    model = Model(
        model_path,
        n_threads=THREADS,
        language="ko",
        print_progress=False,
        print_realtime=False,
        print_timestamps=False,
    )

    results = []
    for audio in audios:
        started = time.perf_counter()
        segments = model.transcribe(audio)
        text = " ".join(segment.text for segment in segments)
        results.append((text, time.perf_counter() - started))
    return results


def transcribe_sherpa(model_path: str, audios: list[np.ndarray]) -> list[tuple[str, float]]:
    """SenseVoice int8 ONNX를 sherpa-onnx로 돌린다 — 앱에 넣게 될 런타임이다."""
    import sherpa_onnx

    tokens = Path(model_path).with_name("sensevoice-tokens.txt")
    for required in (Path(model_path), tokens):
        if not required.exists():
            raise FileNotFoundError(f"{required}이 없습니다.")

    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=model_path,
        tokens=str(tokens),
        num_threads=THREADS,
        language="ko",
        use_itn=False,  # fp32 경로와 같은 조건으로 맞춘다.
        debug=False,
    )

    results = []
    for audio in audios:
        started = time.perf_counter()
        stream = recognizer.create_stream()
        stream.accept_waveform(SAMPLE_RATE, audio)
        recognizer.decode_stream(stream)
        results.append((stream.result.text, time.perf_counter() - started))
    return results


RUNNERS = {
    "transformers": transcribe_transformers,
    "funasr": transcribe_funasr,
    "whispercpp": transcribe_whispercpp,
    "sherpa": transcribe_sherpa,
}


# --- 실행 -------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audio", type=Path, action="append", default=[])
    parser.add_argument("--dir", type=Path, action="append", default=[], dest="dirs")
    # 모델 하나만 다시 재는 일이 반복된다 — CPU 추론이 오래 걸려서 전체를
    # 다시 돌리는 것이 아깝다.
    parser.add_argument("--only", help="라벨에 이 문자열이 든 모델만 돌린다")
    args = parser.parse_args()
    if not args.audio and not args.dirs:
        parser.error("--audio 또는 --dir 중 하나는 있어야 합니다.")

    models = [m for m in MODELS if not args.only or args.only in m[0]]
    if not models:
        parser.error(f"--only {args.only!r}에 맞는 모델이 없습니다.")

    clips = collect_clips(args.audio, args.dirs)
    truths = [truth for _, _, truth in clips]
    audios = [audio for _, audio, _ in clips]

    total_seconds = sum(len(a) for a in audios) / SAMPLE_RATE
    total_chars = sum(len(normalize(t)) for t in truths)
    device = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "CPU"

    print(
        f"[입력] {len(clips)}개 클립, {total_seconds / 60:.1f}분, 정답 {total_chars}자 "
        f"(한 글자 = CER {100 / total_chars:.2f}%p)",
        file=sys.stderr,
    )
    print(f"[환경] {device}, fp32, 양자화 없음\n", file=sys.stderr)

    summary = []
    details: dict[str, list[tuple[float, str, str, str]]] = {}
    for label, runtime, model_id in models:
        print(f"[실행] {label} ({model_id})", file=sys.stderr)
        try:
            outputs = RUNNERS[runtime](model_id, audios)
        except Exception as error:  # 한 모델이 죽어도 나머지는 계속 잰다.
            print(f"    실패: {type(error).__name__}: {error}", file=sys.stderr)
            summary.append((label, None, None, None, f"{type(error).__name__}: {error}"))
            continue

        hypotheses = [text for text, _ in outputs]
        elapsed = sum(seconds for _, seconds in outputs)

        # 코퍼스 단위 CER — 총 편집거리를 총 정답 길이로 나눈다. 클립별 CER의
        # 평균을 쓰면 짧은 클립이 과도한 가중을 받는다.
        refs = [normalize(t) for t in truths]
        hyps = [normalize(h) for h in hypotheses]
        cer = jiwer.cer(refs, hyps)
        # 자모 CER — 발음이 비슷한 오류에 부분 점수를 준다(to_jamo 참조).
        jamo = jiwer.cer([to_jamo(r) for r in refs], [to_jamo(h) for h in hyps])
        summary.append((label, cer, jamo, elapsed, None))

        details[label] = sorted(
            (
                (jiwer.cer(normalize(t), normalize(h)), path.name, t.strip(), h.strip())
                for (path, _, t), h in zip(clips, hypotheses)
            ),
            key=lambda row: -row[0],
        )
        print(f"    CER {cer:.1%}  자모 {jamo:.1%}  추론 {elapsed:.1f}초", file=sys.stderr)

    print(f"## 결과 — {len(clips)}개 클립, {total_seconds / 60:.1f}분, 정답 {total_chars}자\n")
    print(f"한 글자가 CER {100 / total_chars:.2f}%p다. 이보다 작은 차이는 우연이다.\n")
    print("| 모델 | CER | 자모 CER | 추론 시간(초) |")
    print("|---|---|---|---|")
    for label, cer, jamo, elapsed, failure in summary:
        if failure:
            print(f"| {label} | 실패: {failure} | — | — |")
        else:
            print(f"| {label} | {cer:.1%} | {jamo:.1%} | {elapsed:.1f} |")

    print("\n**자모 CER**은 한글 음절을 자모로 분해해 재므로 발음이 비슷한 오류에")
    print("부분 점수를 준다(`것` 대 `거` = 3분의 1 오류). 분모가 2~3배라 CER과")
    print("절대값을 비교하면 안 되고, 모델 간 상대 비교에만 쓴다.")

    print("\n추론 시간은 모델 로딩을 뺀 순수 추론이다.")
    print(f"**fp32는 GPU, 양자화는 CPU({THREADS}스레드)다 — 두 묶음의 시간을 서로")
    print("비교하면 안 된다.** 양자화 쪽이 앱과 같은 런타임·같은 스레드 수라서")
    print("폰 시간의 대리 지표로 쓸 수 있다(PC CPU가 더 빠르므로 절대값이 아니라")
    print("모델 간 비율만).\n")

    print("## 가장 많이 틀린 클립\n")
    for label, rows in details.items():
        print(f"### {label}\n")
        for cer, name, truth, hypothesis in rows[:5]:
            print(f"- **{name}** — CER {cer:.1%}")
            print(f"  - 정답: `{' '.join(truth.split())}`")
            print(f"  - 인식: `{' '.join(hypothesis.split())}`")
        print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
