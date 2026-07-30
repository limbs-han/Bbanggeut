"""잡음 환경에서 whisper.cpp 파라미터를 A/B로 잰다.

> **결과(2026-07-30): 이득이 없다. 이 경로는 닫혔다.**
>
> | 설정 | meeting | phone |
> |---|---|---|
> | 기준 | 16.3% | 35.6% |
> | suppress_nst=True | 16.3% | 35.6% |
> | no_speech_thold=0.8 | 16.3% | 35.6% |
> | entropy_thold=3.0 | 16.3% | 35.6% |
> | 셋 다 | 16.3% | 35.6% |
>
> 소수점까지 동일하다. **파라미터는 정상 적용됐다** — `get_params()`로
> `suppress_nst=True`, `no_speech_thold=0.80`, `entropy_thold=3.00`을 확인했다.
> 적용됐는데 결과가 안 바뀌는 이유는 **이 값들이 temperature fallback 경로에서만
> 쓰이고, temperature=0에서는 fallback이 트리거되지 않기** 때문이다.
>
> 같은 이유로 `best_of`도 무효였다(5→1에서 49.3초→46.6초, CER 동일). 즉
> **whisper.cpp의 디코딩 파라미터 대부분은 temperature=0에서 손댈 여지가 없다.**
> `whisper_ggml_plus` 포크를 검토할 근거가 사라졌다.
>
> 이 스크립트는 그 판정의 재현용으로 남긴다. 다른 파라미터를 시험하려면
> `VARIANTS`에 추가하되, **temperature 관련 경로가 아닌 것**을 골라라.

모델을 바꾸지 않고 얻을 개선이 남았는지 확인하는 것이 목적이다. 양자화는
이미 최적점(q5_1)에 도달했고 — q8_0·q4_0·q5_0이 잡음 조건에서 모두 q5_1보다
나빴다 — 남은 것은 디코딩 파라미터다.

**두 잡음 조건에서 일관되게 0.6%p 이상 나아져야 채택한다.** 0.06%p가 한
글자이므로 그보다 작은 차이는 우연이고, 그걸 근거로 코드를 바꾸면 노이즈를
제도화하는 셈이다. 한 조건만 좋아지는 것도 버린다 — q4_0이 낭독에서만 좋고
8kHz에서 최악이었던 것과 같은 함정이다.

    python tune_params.py --dir dataset/meeting --dir dataset/phone

**주의**: 여기서 이득이 나와도 앱에 바로 적용할 수는 없다. `whisper_ggml_plus`의
`TranscribeRequest`가 이 파라미터들을 노출하지 않으므로 패키지를 포크해야 한다.
이 측정은 그 비용을 지불할 근거가 있는지 판단하기 위한 것이다.
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

import jiwer

from run_benchmark import APP_ASSET, THREADS, collect_clips, normalize

# (이름, pywhispercpp에 넘길 파라미터)
#
# 기본값은 whisper.cpp가 정한 것이다(no_speech_thold=0.6, suppress_nst=False,
# entropy_thold=2.4). 잡음 환경에서 환청·반복이 늘어나는 것이 whisper의 알려진
# 약점이라, 침묵 판정을 엄격하게 하거나 비발화 토큰을 억제하면 나아질 수 있다.
VARIANTS = [
    ("기준 (whisper.cpp 기본값)", {}),
    ("suppress_nst=True", {"suppress_nst": True}),
    ("no_speech_thold=0.8", {"no_speech_thold": 0.8}),
    ("entropy_thold=3.0", {"entropy_thold": 3.0}),
    ("셋 다", {"suppress_nst": True, "no_speech_thold": 0.8, "entropy_thold": 3.0}),
]


def measure(model_path: str, audios: list, truths: list[str], params: dict) -> tuple[float, float]:
    from pywhispercpp.model import Model

    model = Model(
        model_path,
        n_threads=THREADS,
        language="ko",
        print_progress=False,
        print_realtime=False,
        print_timestamps=False,
        **params,
    )
    started = time.perf_counter()
    hypotheses = [" ".join(s.text for s in model.transcribe(a)) for a in audios]
    elapsed = time.perf_counter() - started
    del model

    cer = jiwer.cer(
        [normalize(t) for t in truths],
        [normalize(h) for h in hypotheses],
    )
    return cer, elapsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, action="append", required=True, dest="dirs")
    args = parser.parse_args()

    results: dict[str, dict[str, float]] = {}
    for directory in args.dirs:
        clips = collect_clips([], [directory])
        audios = [a for _, a, _ in clips]
        truths = [t for _, _, t in clips]
        chars = sum(len(normalize(t)) for t in truths)
        print(
            f"\n[{directory.name}] {len(clips)}클립, 정답 {chars}자 "
            f"(한 글자 = {100 / chars:.2f}%p)"
        )

        for label, params in VARIANTS:
            cer, elapsed = measure(str(APP_ASSET), audios, truths, params)
            results.setdefault(label, {})[directory.name] = cer
            print(f"  {label:32s} CER {cer:.1%}  {elapsed:.0f}초")

    names = [d.name for d in args.dirs]
    print(f"\n## 요약 — small-ko q5_1, {THREADS}스레드\n")
    print("| 설정 | " + " | ".join(names) + " | 기준 대비 |")
    print("|---" * (len(names) + 2) + "|")
    base = results["기준 (whisper.cpp 기본값)"]
    for label, per in results.items():
        cells = " | ".join(f"{per[n]:.1%}" for n in names)
        deltas = [base[n] - per[n] for n in names]  # 양수 = 개선
        gain = " / ".join(f"{d * 100:+.1f}%p" for d in deltas)
        print(f"| {label} | {cells} | {gain} |")

    print("\n**채택 기준: 모든 조건에서 +0.6%p 이상.** 0.06%p가 한 글자이므로")
    print("그보다 작은 차이는 우연이고, 한 조건만 좋아지는 것은 범용성을 잃는다.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
