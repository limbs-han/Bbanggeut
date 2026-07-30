# STT 모델 가이드 (AI/코딩 에이전트용)

> 기준: 2026-07-29 / 측정 완료
> 사람용 원본: [../사람이 읽을 문서/05-STT모델가이드.md](../사람이%20읽을%20문서/05-STT모델가이드.md)
> 관련 ID: `FN-A39`(온디바이스 자동 자막) — 상세는 [`03-features.md`](./03-features.md)

이 문서는 산문 설명을 제거하고 표/리스트만으로 구성한 파생 문서다. 사실·수치는 사람용
원본과 동일하다.

---

## 1. 현재 상태

| 항목 | 값 |
|---|---|
| 모델 | `SungBeom/whisper-small-ko`를 **q5_1**로 양자화 (2026-07-29 q5_0에서 교체) |
| 에셋 경로 | `frontend/assets/models/ggml-small-ko-q5_1.bin` |
| 크기 | 190,085,504바이트 (약 181MiB) |
| 런타임 | whisper.cpp (`whisper_ggml_plus` pub 패키지) |
| 추론 스레드 | 6 (`whisper_transcriber.dart`, 실측으로 정함) |
| 속도 (S24) | 120초 클립 → 168초 / 침묵 제외 시 109초 |
| 외부 전송 | 없음. 오디오·전사문이 기기 밖으로 나가지 않는다 |

## 2. ⚠️ 금지 사항 — 코드 작성 전 반드시 확인

| 금지 | 이유 |
|---|---|
| **fp32 CER 값을 앱 성능으로 인용하지 마라** | `small-ko` fp32 6.2%는 GPU 미양자화 값이다. 앱이 배포하는 양자화 형태는 **11.3%**다. "폰에서 상용 API 1위급"은 사실이 아니다 |
| **q4_0으로 용량을 줄이지 마라** | 낭독 3.4%로 좋아 보이지만 8kHz에서 **41.0%로 최악**이다. 사람용 원본에 남아 있던 "q4_0으로 120MiB" 카드는 폐기됐다 |
| **`small-ko`가 항상 최선이라고 가정하지 마라** | 도메인에 따라 뒤집힌다(3절). 저음질에서는 `turbo`가 3.5배 낫다 |
| **모델 파일 이름을 바꾸지 않고 내용만 교체하지 마라** | 앱은 파일 이름으로 기기 사본의 갱신 여부를 판단한다(`whisper_model.dart`). 이름이 같으면 옛 사본을 계속 쓴다 |
| **PC GPU 추론 시간으로 폰 속도를 추정하지 마라** | fp32는 GPU, 양자화는 CPU다. 두 묶음의 시간은 비교 불가 |

## 3. 측정 결과 — 도메인별 CER

정답 총량이 셋 다 1400자 안팎(한 글자 = 0.07%p)이라 나란히 비교 가능.

| 모델 | zeroth<br>낭독 16kHz | kspon<br>대화 16kHz | phone<br>전화 8kHz |
|---|---|---|---|
| `small-ko` fp32 | 2.1% | **6.2%** | 28.6% |
| `turbo` fp32 | 1.4% | 11.8% | **8.1%** |
| `SenseVoiceSmall` fp32 | **0.4%** | 13.8% | 29.5% |
| `small-ko` q5_0 (교체 전) | 10.7% | 11.5% | 37.6% |
| `small-ko` q4_0 | 3.4% | 11.2% | 41.0% |
| `small-ko` q5_1 ← **현재 배포** | **2.9%** | 11.3% | **35.6%** |
| `SenseVoiceSmall` int8 | 0.7% | 13.9% | **27.3%** |

- 데이터셋: `Bingsu/zeroth-korean` test / `DragonLine/ksponspeech_eval_clean` test /
  AI Hub 저음질 전화망(571) Validation
- 클립 수: 28 / 96 / 48. 정답: 1361자 / 1438자 / 1432자
- 집계: 코퍼스 단위 CER (총 편집거리 ÷ 총 정답 길이)

## 4. 양자화 사다리 (`small-ko`, zeroth 기준)

| 종류 | CER | 크기 | 추론(PC CPU 6스레드) | 상태 |
|---|---|---|---|---|
| fp16 | 2.9% | 465MB | 79.4초 | 참고 |
| q8_0 | 2.9% | 252MB | 59.3초 | 참고 |
| q5_1 | **2.9%** | 181MB | 74.5초 | ✅ 현재 배포 |
| q5_0 | **10.7%** | 167MB | 74.3초 | 교체 전(2026-07-29까지) |
| q4_0 | 3.4% | 139MB | 45.5초 | ❌ 금지 (8kHz 41.0%) |

- **정밀도 순서가 깨져 있다** — 4비트(q4_0)가 5비트(q5_0)를 3배 이긴다. q5_0의 5비트
  패킹이 이 모델과 맞지 않는다.
- q5_0의 격차는 낭독에서만 크다. 대화·전화에서는 q5_0/q4_0/q5_1이 0.2~2%p 안에 모인다.
- 양자화 자체의 대가는 포맷을 바꿔도 남는다: fp32 6.2% → q5_1 11.3% (kspon).

## 5. 결정 상태

| 항목 | 상태 |
|---|---|
| q5_1로 교체 | ✅ **적용 완료 (2026-07-29).** 세 조건 모두에서 이득 (+14MB, 추론 시간 동일) |
| `small-ko` vs `turbo` | ⚠️ **미결.** 홈캠 오디오가 kspon(→small-ko)인지 phone(→turbo)인지 모른다 |
| `SenseVoiceSmall` 채택 | ❌ 탈락. 대화·전화에서 꼴등. 낭독만 1위(0.4%). 런타임 교체(sherpa-onnx) 필요 + 모델 가중치 라이선스 회색 |
| q4_0 채택 | ❌ 폐기 (2절) |
| 실기기(S24) 측정 | ⚠️ 미실시. PC 값만 있음 |

**미결 해소 조건**: 홈캠 기기(`ai/device_agent/local-recording.sh`)로 30초×10개 녹음,
정답 500자 이상, 아이 목소리 포함. 표기 규칙은 사람용 원본 4부 참조.

## 6. 경로 매핑

| 대상 | 경로 |
|---|---|
| 모델 확보 로직 | `frontend/lib/features/stt/whisper_model.dart` (`whisperModelAsset` 상수, `WHISPER_MODEL_PATH` dart-define) |
| 전사 로직 | `frontend/lib/features/stt/whisper_transcriber.dart` (`threads=6`) |
| 에셋 등록 | `frontend/pubspec.yaml` (`assets:` 목록) |
| 모델 테스트 | `frontend/test/whisper_model_test.dart` — **문서 파일명을 문자열로 검사한다.** 문서를 옮기면 함께 고쳐야 한다 |
| 벤치마크 | `ai/stt_benchmark/run_benchmark.py`, `fetch_dataset.py`, `test_run_benchmark.py` |
| 벤치마크 데이터·모델 | `ai/stt_benchmark/{dataset,models}/` — `.gitignore` 대상 |

## 7. 절차 (명령만)

### 모델 교체

```bash
# 1) HF → GGML fp16 (컴파일러 불필요. 3번째 인자는 openai-whisper의 site-packages)
python whisper.cpp/models/convert-h5-to-ggml.py <hf-dir> <site-packages> <out-dir>

# 2) 양자화 (PC에서 됨. gcc 16.1 필요 — conda의 gcc 5.3은 C++17 미지원)
winget install BrechtSanders.WinLibs.POSIX.UCRT
cmake -B build -G "MinGW Makefiles" -DWHISPER_BUILD_EXAMPLES=ON -DBUILD_SHARED_LIBS=OFF
cmake --build build --target whisper-quantize -j
build/bin/whisper-quantize ggml-model.bin ggml-small-ko-q5_1.bin q5_1
```

- 실행 시 **gcc `bin`을 PATH에 넣어야 한다** — 안 넣으면 출력 없이 죽는다(종료 코드만).
- 출력 폴더는 미리 만들어야 한다(없으면 죽는다).
- PC 결과 = 기기 결과 (SHA256 대조로 확인).
- 3) 에셋 교체: `pubspec.yaml`의 `assets:`와 `whisper_model.dart`의 `whisperModelAsset`을
  **함께** 고친다(2절 금지 사항 참조).

### 벤치마크

```bash
cd ai/stt_benchmark
python test_run_benchmark.py                                  # 정규화 점검 (필수)
python fetch_dataset.py --name kspon --minutes 5 --out dataset/kspon
python run_benchmark.py --dir dataset/kspon --only small-ko    # --only는 라벨 부분일치
python run_benchmark.py --audio <클립.m4a>                     # 정답: <이름>_original.txt
```

## 8. 알려진 함정

| 함정 | 증상 | 대응 |
|---|---|---|
| 정답 파일 인코딩 오독 | 세 모델이 나란히 비슷한 CER(예: 57%대) → 모델 탓으로 오판 | UTF-16은 **BOM으로만** 판별. `read_truth()`가 처리. `test_run_benchmark.py`가 검사 |
| 정규화 누락 | SenseVoice·AI Hub 태그가 CER을 부풀린다 | `normalize()` 하나만 쓴다. `<\|...\|>`, `n/` `o/`, `(())`, 이중 표기 `(A)/(B)`→A 처리 |
| 표본 부족 | 47자 클립에서 한 글자 = CER 2.1%p → 순위가 우연으로 갈린다 | 정답 500자 이상 확보 후 판단 |
| 런타임 vs 양자화 혼동 | fp32(transformers)와 q5_0(whisper.cpp) 차이를 양자화 탓으로 오판 | 같은 whisper.cpp 안에서 fp16과 비교해야 분리된다. turbo 기준 런타임 차이는 **0** |
| `language="ko"` 거부 | `small-ko`가 ValueError | generation config가 낡아서다. 한국어 전용 모델이라 기본값으로 돌리면 된다 |
| PowerShell `Set-Content -Encoding utf8` | 파일에 BOM 삽입 → `pubspec.yaml` 파싱 위험 | `[System.IO.File]::WriteAllText`에 `UTF8Encoding($false)` 사용 |

## 9. 외부 비교 (rtzr, KsponSpeech eval clean)

| API / 모델 | CER |
|---|---|
| Return Zero | 6.64% |
| **우리 `small-ko` fp32** | **6.2%** |
| Naver ClovaSpeech | 8.05% |
| AWS Transcribe | 8.58% |
| ETRI | 9.99% |
| **우리 `small-ko` q5_1 (배포 형태)** | **11.3%** |
| Google API v2 | 11.82% |
| **우리 `turbo` fp32** | **11.8%** |
| OpenAI Whisper | 12.06% |
| Deepgram nova-2 | 23.48% |

출처: <https://github.com/rtzr/Awesome-Korean-Speech-Recognition>

- 우리 turbo 11.8% ≈ 그들 OpenAI Whisper 12.06% → 측정 파이프라인 교차 검증됨.
- 차이 요인: 표본(그들 3000문장 / 우리 1438자), 정규화 규칙(그들 미공개), 전사 방식
  (그들 철자 우선 / 우리가 쓴 미러는 발음 전사로 보임 — **우리에게 불리**).
