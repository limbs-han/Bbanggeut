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
| 속도 (S24, 앱) | 120초 클립 → 168초 / 침묵 제외 시 109초 |
| 속도 (S24, whisper-cli 실측) | 120초 오디오 → **49.3초** (앱 조건: greedy + best_of 5, 6스레드). turbo는 같은 조건에서 184.2초 |
| 외부 전송 | 없음. 오디오·전사문이 기기 밖으로 나가지 않는다 |

## 2. ⚠️ 금지 사항 — 코드 작성 전 반드시 확인

| 금지 | 이유 |
|---|---|
| **fp32 CER 값을 앱 성능으로 인용하지 마라** | `small-ko` fp32 6.2%는 GPU 미양자화 값이다. 앱이 배포하는 양자화 형태는 **11.3%**다. "폰에서 상용 API 1위급"은 사실이 아니다 |
| **q4_0으로 용량을 줄이지 마라** | 낭독 3.4%로 좋아 보이지만 8kHz에서 **41.0%로 최악**이다. "q4_0으로 120MiB" 카드는 폐기됐다 |
| **q8_0으로 정확도를 올리려 하지 마라** | 8비트인데 5비트(q5_1)보다 **나쁘다** — 잡음 두 조건에서 열세고 크기는 +71MB. 이 모델에서 "비트 늘리면 정확해진다"가 성립하지 않는다 |
| **`small-ko`가 항상 최선이라고 가정하지 마라** | 도메인에 따라 뒤집힌다(3절). 저음질에서는 `turbo`가 3.5배 낫다 |
| **모델 파일 이름을 바꾸지 않고 내용만 교체하지 마라** | 앱은 파일 이름으로 기기 사본의 갱신 여부를 판단한다(`whisper_model.dart`). 이름이 같으면 옛 사본을 계속 쓴다 |
| **PC GPU 추론 시간으로 폰 속도를 추정하지 마라** | fp32는 GPU, 양자화는 CPU다. 두 묶음의 시간은 비교 불가 |

## 3. 측정 결과 — 도메인별 CER

정답 총량이 셋 다 1400자 안팎(한 글자 = 0.07%p)이라 나란히 비교 가능.

| 모델 | zeroth<br>낭독 | kspon<br>대화 | **phone<br>8kHz** | **meeting<br>잡음회의** |
|---|---|---|---|---|
| `small-ko` fp32 | 2.1% | **6.2%** | 28.6% | **10.3%** |
| `turbo` fp32 | 1.4% | 11.8% | **8.1%** | 9.8% |
| `SenseVoiceSmall` fp32 | **0.4%** | 13.8% | 29.5% | 12.2% |
| `small-ko` q5_0 (교체 전) | 10.7% | 11.5% | 37.6% | 19.4% |
| `small-ko` q4_0 | 3.4% | 11.2% | 41.0% | — |
| `small-ko` q8_0 | 2.9% | — | 37.8% | 16.8% |
| `small-ko` q5_1 ← **최종 채택** | **2.9%** | 11.3% | **35.6%** | **16.3%** |
| `SenseVoiceSmall` int8 | 0.7% | 13.9% | **27.3%** | **13.9%** |

- 데이터셋: `Bingsu/zeroth-korean` test / `DragonLine/ksponspeech_eval_clean` test /
  AI Hub 저음질 전화망(571) / **AI Hub 회의 음성(464), `environment ∈ {잡음, 배경 음악}`**
- 클립 수: 28 / 96 / 48 / 50. 정답: 1361 / 1438 / 1430 / 1636자
- 집계: 코퍼스 단위 CER (총 편집거리 ÷ 총 정답 길이)

**phone의 큰 격차는 8kHz 특수 조건에 기댄다.** 16kHz 잡음(meeting)에서는 `small-ko` fp32
10.3%, `turbo` 9.8%로 거의 같다. 홈캠은 8kHz가 아니므로 **meeting이 더 가까운 지표다.**

## 4. 양자화 사다리 (`small-ko`, zeroth 기준)

**한 조건만 보면 속는다.** 낭독과 잡음 두 조건을 함께 본다.

| 종류 | zeroth | **phone** | **meeting** | 크기 | 상태 |
|---|---|---|---|---|---|
| fp16 | 2.9% | — | — | 465MB | 참고 |
| q8_0 | 2.9% | 37.8% | 16.8% | 252MB | ❌ **금지** (잡음 두 조건 열세, 크기 +71MB) |
| **q5_1** | **2.9%** | **35.6%** | **16.3%** | **181MB** | ✅ **최종 채택** |
| q5_0 | **10.7%** | 37.6% | 19.4% | 167MB | 교체 전(2026-07-29까지) |
| q4_0 | 3.4% | 41.0% | — | 139MB | ❌ 금지 (8kHz 최악) |

- **q5_1이 모든 조건에서 최선이다. 양자화로 더 얻을 것이 없다.**
- **정밀도 순서가 두 번 깨진다** — 낭독에서 4비트가 5비트(q5_0)를 3배 이기고, 잡음에서
  8비트(q8_0)가 5비트(q5_1)보다 나쁘다. 미세조정된 small 모델의 가중치 분포가 표준 양자화
  가정과 맞지 않는 것으로 보인다. **추정하지 말고 조건별로 재라.**
- 양자화 대가는 포맷을 바꿔도 남는다: meeting fp32 10.3% → q5_1 16.3% (**+6.0%p**).
  SenseVoice int8은 +1.7%p뿐이라 배포 형태에서 순위가 뒤집힌다.

## 5. 결정 상태

| 항목 | 상태 |
|---|---|
**도메인 판단(2026-07-30)**: 홈캠은 **잡음 있는 환경**의 성능이 중요하다. 아이 목소리는
고려 대상에서 뺀다. 그래서 **phone 열을 기준으로 읽는다.**

**선정 규칙(측정 전에 정했다)**: 배포 형태끼리 비교해 **잡음 두 조건 모두에서 3%p 이상**
앞서야 교체한다. 결론을 보고 완화하지 않았다.

| 항목 | 상태 |
|---|---|
| **`small-ko` q5_1** | ✅ **최종 채택.** 2026-07-29 q5_0에서 교체 완료 |
| `turbo` 채택 | ❌ **탈락 (실기기).** 앱 조건 3.7배 느림(184.2초 대 49.3초/120초). 10분 영상에 약 34분. 에셋 547MB·복사 시 1.1GB·메모리에 한 번에 올림 |
| q8_0 / q4_0 / q5_0 | ❌ **탈락.** 잡음 두 조건에서 q5_1보다 나쁘다 (4절) |
| **`SenseVoiceSmall`** | ⚠️ **보류(탈락 아님).** 잡음에서 앞서지만(phone 8.3%p, **meeting 2.4%p**) meeting이 3%p 기준 미달. **속도 15.7배가 유인** |
| 양자화 추가 개선 | ❌ **경로 없음.** q5_1이 최적점 |

**이전 판정 취소 기록**: 이 문서는 SenseVoice를 "대화·전화에서 꼴등"이라며 탈락으로 적었다.
근거는 kspon 13.9% 하나였고, 잡음 환경이 중요하다는 판단이 정해지면서 무효가 됐다.
**지금은 보류다.**

**SenseVoice를 다시 볼 조건 셋**: ① 실기기 속도(sherpa-onnx 안드로이드 빌드 필요) —
**CPU에서는 GPU 기준 예측이 배신한다**(turbo의 얕은 decoder 장점이 encoder에 압도됐다).
② 자막 줄 나누기 — CTC라 토큰 타임스탬프만 준다. `speech_analysis.dart`의 발화 구간 검출을
재사용하되 **CER로는 검증되지 않으므로 눈으로 봐야 한다.** ③ 라이선스 — FunASR Model Open
Source License Agreement, 상업적 사용 조항이 회색.

**닫힌 경로 둘 — 다시 시도하지 마라.**

| 경로 | 왜 닫혔나 |
|---|---|
| 양자화 개선 | q5_1이 최적점. q8_0·q4_0·q5_0 전부 잡음 조건에서 열세 |
| **디코딩 파라미터 튜닝** | `suppress_nst` / `no_speech_thold` / `entropy_thold`를 A/B했더니 다섯 설정이 **소수점까지 동일**(meeting 16.3%, phone 35.6%). 파라미터는 `get_params()`로 적용 확인됨. **temperature fallback 경로에서만 쓰이는 값이라 temperature=0에서는 무효다.** `best_of`도 같은 이유로 무효였다. 재현: `tune_params.py` |

**남은 개선 경로**: 자막 생성 시점 이동(UX) → SenseVoice 재검토 → 잡음 미세조정.
**데이터셋 하나에 맞춘 후처리는 하지 마라** — CER은 낮아지지만 앱에서 아무것도 개선하지
않고 측정만 망친다.

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
| **AI Hub 원천 zip에 UTF-8 플래그 없음** | 한글 경로가 cp437로 오독(`인터넷방송`→`└╬┼═│▌╣µ╝█`) → 라벨과 짝이 **0/957** → "0개 추출됨"이라는 애매한 실패 | `name.encode('cp437').decode('cp949')`. `fetch_dataset.py`가 처리 |
| **`/(bgm)` `/(noise)` 배경음 표기** | 괄호·슬래시만 지우면 `bgm`이 정답에 남는다 — meeting에서 **정답의 8.7%** | `_TAG`가 `/\([^)]*\)`를 제거. 순위는 안 바뀌지만 절대값이 오염돼 데이터셋 간 비교가 깨진다 |
| **이중 표기 순서가 데이터셋마다 반대** | phone은 앞이 철자, meeting은 뒤가 철자. 잘못 택하면 모델이 "9건"을 낼 때 정답이 "아홉 건"이라 전부 오류 | `fetch_dataset.py`의 `DUAL_SPELLING_GROUP`이 추출 시 푼다. `normalize()`는 하나를 공유 |
| **양자화 정밀도 순서 위반** | 이 모델은 q4_0>q5_0(낭독), q5_1>q8_0(잡음)이다. "비트 늘리면 정확"이 성립하지 않는다 | 추정하지 말고 **조건별로 재라**. 4절 표가 기록 |

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
