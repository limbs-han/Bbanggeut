"""한국어 음성 데이터셋에서 벤치마크용 샘플을 뽑는다.

`run_benchmark.py`가 읽는 형식으로 저장한다 — 오디오 파일과 같은 이름의
`<이름>_original.txt`에 정답을 넣는다.

HuggingFace 공개 데이터셋:

    python fetch_dataset.py --name zeroth --minutes 5 --out dataset/zeroth
    python fetch_dataset.py --name kspon  --minutes 5 --out dataset/kspon

AI Hub 데이터셋(직접 내려받은 zip에서 뽑는다 — 압축을 풀지 않는다):

    python fetch_dataset.py --name phone --minutes 5 --out dataset/phone \
      --labels-zip "<571>/2.Validation/라벨링데이터_230316/VL_D03.zip" \
      --audio-zip  "<571>/2.Validation/원천데이터_230316/VS_D03.zip"

    python fetch_dataset.py --name meeting --minutes 5 --out dataset/meeting \
      --labels-zip "<464>/2.Validation/라벨링데이터_260312_add/VL1.zip" \
      --audio-zip  "<464>/2.Validation/원천데이터_.../VS1.zip"

**데이터셋마다 성격이 다르다** — 그래서 다 재고 순위가 유지되는지 본다.

  zeroth  : 낭독. 깨끗한 근접 마이크. 16kHz.
  kspon   : 자유대화. 스튜디오 녹음. 간투어·구어체 살림. 2인, 발화 단위로 잘림.
  phone   : 전화 상담. **8kHz narrow band** — 정보량이 적어 가장 어렵다.
  meeting : 회의·토론. **3~5인이 절반**이라 겹쳐 말하기가 있다. 매체가 방송
            위주라 기본적으로 깨끗하지만, `environment` 필드로 **잡음 조건만
            골라낼 수 있다**(기본 동작). 그 필터가 이 데이터셋의 존재 이유다.

오디오는 디코딩하지 않고 원본 bytes로 저장한다. 최신 datasets는 오디오
디코딩에 torchcodec을 요구하고 그것이 다시 시스템 ffmpeg를 요구하는데, 이
환경에는 없다. `run_benchmark.py`가 PyAV로 읽으므로 디코딩은 거기서 한 번만
일어난다(8kHz도 거기서 16kHz로 리샘플된다).
"""

from __future__ import annotations

import argparse
import io
import json
import re
import zipfile
from pathlib import Path
from typing import Iterator

import av

from run_benchmark import normalize

# 이중 표기 `(A)/(B)`에서 철자 쪽이 몇 번째인가 — **데이터셋마다 반대다.**
#   phone(571)   : (12월)/(십 이 월)   → 앞
#   meeting(464) : (아홉 건의)/(9건의) → 뒤
# 철자를 택하는 이유: 모델이 실제로 "9건", "TBS FM"을 내놓고, rtzr 벤치마크도
# 철자를 우선했다고 밝혔다 — 그쪽 점수와 견주려면 맞춰야 한다.
# 여기서 풀어 저장하므로 `normalize()`는 데이터셋을 몰라도 된다.
_DUAL = re.compile(r"\(([^()]*)\)/\(([^()]*)\)")
DUAL_SPELLING_GROUP = {"phone": 1, "meeting": 2}

# (HF 데이터셋 ID, split, 정답 컬럼 이름)
HF_SOURCES = {
    "zeroth": ("Bingsu/zeroth-korean", "test", "text"),
    "kspon": ("DragonLine/ksponspeech_eval_clean", "test", "transcripts"),
}


def decode_text(raw: bytes) -> str:
    for encoding in ("utf-8-sig", "utf-8", "cp949"):
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    raise SystemExit("전사 텍스트의 인코딩을 알 수 없습니다.")


def guess_suffix(data: bytes) -> str:
    """매직바이트로 컨테이너를 알아낸다.

    zeroth는 `audio.path`가 없어서 확장자를 알 수 없다. PyAV는 확장자와
    무관하게 컨테이너를 감지하므로 기능상 필요는 없지만, 사람이 직접
    들어볼 때 확장자가 맞아야 편하다.
    """
    if data.startswith(b"fLaC"):
        return ".flac"
    if data.startswith(b"RIFF"):
        return ".wav"
    if data.startswith(b"OggS"):
        return ".ogg"
    return ".bin"


def duration_seconds(data: bytes) -> float:
    with av.open(io.BytesIO(data)) as container:
        stream = container.streams.audio[0]
        if stream.duration is not None and stream.time_base is not None:
            return float(stream.duration * stream.time_base)
        if container.duration is not None:
            return container.duration / av.time_base
    raise ValueError("길이를 알 수 없는 오디오")


def iter_huggingface(name: str) -> Iterator[tuple[bytes, str]]:
    from datasets import Audio, load_dataset

    repo, split, column = HF_SOURCES[name]
    # streaming: eval 세트 전체(수 GB)를 받지 않고 앞에서부터 필요한 만큼만 읽는다.
    dataset = load_dataset(repo, split=split, streaming=True)
    dataset = dataset.cast_column("audio", Audio(decode=False))
    for row in dataset:
        yield row["audio"]["bytes"], (row[column] or "").strip()


def iter_aihub(labels_zip: Path, audio_zip: Path) -> Iterator[tuple[bytes, str]]:
    """AI Hub zip 두 개를 짝지어 읽는다. 압축을 풀지 않는다.

    라벨 zip에는 세션 JSON과 발화별 txt가 함께 들어 있는데, **txt 내용이
    JSON의 `text`와 완전히 같다.** 그래서 JSON을 파싱하지 않고 txt를 쓴다.
    경로도 `.../0001.txt` ↔ `.../0001.wav`로 그대로 대응한다.
    """
    with zipfile.ZipFile(labels_zip) as labels, zipfile.ZipFile(audio_zip) as audio:
        available = {n for n in audio.namelist() if n.lower().endswith(".wav")}
        # sorted: 추출 순서를 고정한다. 순서가 달라지면 결과를 비교할 수 없다.
        for entry in sorted(n for n in labels.namelist() if n.lower().endswith(".txt")):
            wav = entry[:-4] + ".wav"
            if wav not in available:
                continue
            yield audio.read(wav), decode_text(labels.read(entry)).strip()


def iter_meeting(
    labels_zip: Path, audio_zip: Path, environments: set[str]
) -> Iterator[tuple[bytes, str]]:
    """AI Hub 회의 음성(464)에서 발화 단위로 뽑는다.

    phone(571)과 두 가지가 다르다.

    1. **오디오가 세션 단위 wav 하나**다(발화 수백 개, 40분 이상). json의
       `start`/`end`로 잘라내야 한다.
    2. **`environment` 필드로 잡음 조건을 고를 수 있다** — 값은 ''(94%),
       '배경 음악'(3.6%), '잡음'(2.3%)이다. 홈캠은 잡음 환경이 중요하므로
       기본값으로 잡음·배경음악만 고른다. 이 필터가 없으면 방송 스튜디오의
       깨끗한 발화가 대부분이라 kspon과 다를 바 없는 측정이 된다.

    정답은 `form`을 쓴다. `original_form`은 이중 표기 없이 발음 쪽만 담아서
    (둘이 39% 다르다) 모델이 철자를 낼 때 불리하다.
    """
    import soundfile as sf

    with zipfile.ZipFile(labels_zip) as labels, zipfile.ZipFile(audio_zip) as audio:
        # 원천데이터 zip에는 UTF-8 플래그가 없어서 zipfile이 한글 경로를 cp437로
        # 디코딩한다("인터넷방송" → "└╬┼═│▌╣µ╝█"). 되돌리지 않으면 라벨과 짝이
        # 하나도 안 맞는다 — 실제로 0/957이 나왔다. 라벨 zip은 플래그가 있어 정상.
        available = {}
        for name in audio.namelist():
            if not name.lower().endswith(".wav"):
                continue
            try:
                available[name.encode("cp437").decode("cp949")] = name
            except (UnicodeDecodeError, UnicodeEncodeError):
                available[name] = name
        # sorted: 추출 순서를 고정한다. 순서가 달라지면 결과를 비교할 수 없다.
        for entry in sorted(n for n in labels.namelist() if n.lower().endswith(".json")):
            wav_name = entry[:-5] + ".wav"
            if wav_name not in available:
                continue

            session = json.loads(labels.read(entry).decode("utf-8-sig"))
            picked = [
                u
                for u in session.get("utterance", [])
                if not environments or (u.get("environment") or "") in environments
            ]
            if not picked:
                continue

            # 세션 wav는 한 번만 읽는다(60분이면 약 120MB). 발화마다 다시 읽으면
            # 같은 파일을 수백 번 압축 해제하게 된다.
            samples, rate = sf.read(
                io.BytesIO(audio.read(available[wav_name])), dtype="float32"
            )
            if samples.ndim > 1:
                samples = samples.mean(axis=1)

            for utterance in picked:
                start = int(float(utterance["start"]) * rate)
                end = int(float(utterance["end"]) * rate)
                clip = samples[start:end]
                if clip.size == 0:
                    continue
                buffer = io.BytesIO()
                sf.write(buffer, clip, rate, format="WAV", subtype="PCM_16")
                yield buffer.getvalue(), (utterance.get("form") or "").strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="zeroth | kspon | 그 외(AI Hub)")
    parser.add_argument("--minutes", type=float, default=5.0)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--labels-zip", type=Path, help="AI Hub 라벨링데이터 zip")
    parser.add_argument("--audio-zip", type=Path, help="AI Hub 원천데이터 zip")
    # 회의 음성(464)에서 잡음 조건만 고를 때 쓴다. 빈 값을 주면 전체.
    parser.add_argument(
        "--environment",
        action="append",
        dest="environments",
        help="meeting 전용. environment 필드 값(잡음 / 배경 음악). "
        "기본값은 잡음·배경음악 둘 다 — 홈캠은 잡음 환경이 중요하다",
    )
    args = parser.parse_args()

    if args.name in HF_SOURCES:
        rows = iter_huggingface(args.name)
    else:
        if not args.labels_zip or not args.audio_zip:
            parser.error(
                f"--name {args.name}은 HF 목록에 없습니다. AI Hub zip을 쓰려면 "
                "--labels-zip과 --audio-zip을 주세요."
            )
        for required in (args.labels_zip, args.audio_zip):
            if not required.exists():
                parser.error(f"zip이 없습니다: {required}")
        if args.name == "meeting":
            environments = set(args.environments or ["잡음", "배경 음악"])
            print(f"[필터] environment in {sorted(environments)}")
            rows = iter_meeting(args.labels_zip, args.audio_zip, environments)
        else:
            rows = iter_aihub(args.labels_zip, args.audio_zip)

    # 이중 표기를 여기서 푼다 — 데이터셋마다 철자 쪽이 반대다.
    spelling = DUAL_SPELLING_GROUP.get(args.name)

    target_seconds = args.minutes * 60
    args.out.mkdir(parents=True, exist_ok=True)
    # 남아 있는 옛 클립을 지운다. 안 그러면 이전 실행의 파일이 섞여
    # 총 길이가 얼마인지 알 수 없게 된다.
    for stale in args.out.iterdir():
        if stale.is_file():
            stale.unlink()

    total_seconds = 0.0
    total_chars = 0
    saved = 0
    skipped_unclear = 0
    for data, truth in rows:
        if total_seconds >= target_seconds:
            break
        if spelling:
            truth = _DUAL.sub(lambda m: m.group(spelling), truth)
        if not data or not normalize(truth):
            continue  # 정답이 비면 CER을 잴 수 없다.
        # AI Hub의 (())는 사람도 알아듣지 못한 구간이다. 정답에 그 말이 빠져
        # 있으므로 모델이 무엇을 내놓아도 오류로 잡힌다 — 발화째로 뺀다.
        if "(())" in truth:
            skipped_unclear += 1
            continue

        seconds = duration_seconds(data)
        saved += 1
        stem = f"{args.name}{saved:03d}"
        (args.out / f"{stem}{guess_suffix(data)}").write_bytes(data)
        (args.out / f"{stem}_original.txt").write_text(truth, encoding="utf-8")

        total_seconds += seconds
        total_chars += len(normalize(truth))

    if not saved:
        raise SystemExit("아무것도 뽑지 못했습니다.")

    print(f"{args.out} — {saved}개 클립, {total_seconds / 60:.1f}분, 정답 {total_chars}자")
    # 한 글자의 무게. 이 값이 CER 차이를 믿을 수 있는 하한을 정한다.
    print(f"한 글자 = CER {100 / total_chars:.2f}%p")
    if skipped_unclear:
        print(f"(()) 구간이 있어 제외한 발화: {skipped_unclear}개")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
