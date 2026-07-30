# STT 모델 — 무엇을 쓰고, 왜, 어떻게 만드나

`features/stt`는 앱에 담긴 whisper.cpp 모델로 영상의 대사를 전사한다. 이 문서 하나가
**모델 선택 근거·측정 결과·만드는 절차**를 전부 담는다.

## 요약

| | 내용 |
|---|---|
| 지금 쓰는 것 | `SungBeom/whisper-small-ko`를 **q5_1**로 양자화 — `frontend/assets/models/ggml-small-ko-q5_1.bin` (190,085,504바이트, 약 181MiB) |
| 교체 이력 | **2026-07-29: q5_0 → q5_1.** q5_0이 낭독에서 CER을 7.8%p 깎고 있었다(1부 참조) |
| 안 쓰기로 한 것 | q4_0(8kHz에서 최악), SenseVoiceSmall(대화에서 꼴등), base급 모델 |
| **미결** | **`small-ko`와 `turbo` 중 무엇을 쓸지.** 홈캠 오디오가 어느 데이터셋에 가까운지 몰라서 결정할 수 없다 |

앱은 첫 실행 때 에셋을 앱 폴더로 복사해서 쓴다 (`whisper_model.dart`) — whisper.cpp는
네이티브에서 파일 경로를 열기 때문에 APK 안에 압축된 에셋을 직접 읽을 수 없다.

**대가**: 저장소가 약 181MiB 커지고 히스토리에 영구히 남는다. 설치 용량도 그만큼 늘어난다
(디버그 APK 366MB — Banuba SDK가 이미 무겁다). 팀 결정으로 받아들였다.

q5_0 → q5_1 교체로 히스토리에는 **두 파일이 모두 남는다**(약 348MiB). 삭제해도 git
히스토리에서는 사라지지 않는다. 모델을 또 바꿀 일이 잦아지면 "첫 사용 시 내려받기"
(4부 3번)로 전환하는 편이 낫다.

---

# 1부. 측정 결과

2026-07-29. PC에서 같은 조건으로 재고, 앱이 실제로 배포하는 양자화 형태까지 함께 쟀다.
벤치마크 코드는 `ai/stt_benchmark/`.

## 도메인이 순위를 정한다 — 세 데이터셋에서 1등이 다 다르다

| 모델 | zeroth<br>낭독 16kHz | kspon<br>대화 16kHz | phone<br>전화 8kHz |
|---|---|---|---|
| `small-ko` fp32 | 2.1% | **6.2%** | 28.6% |
| `turbo` fp32 | 1.4% | 11.8% | **8.1%** |
| `SenseVoiceSmall` fp32 | **0.4%** | 13.8% | 29.5% |
| `small-ko` q5_0 (교체 전) | 10.7% | 11.5% | 37.6% |
| `small-ko` q4_0 | 3.4% | 11.2% | 41.0% |
| **`small-ko` q5_1 — 앱이 지금 배포** | **2.9%** | 11.3% | **35.6%** |
| `SenseVoiceSmall` int8 | 0.7% | 13.9% | **27.3%** |

**깨끗한 대화에서는 한국어 미세조정이 크기를 이긴다.** kspon에서 `small-ko`(244M)가
파라미터 3.3배인 `turbo`(809M)를 두 배 차이로 이긴다.

**저음질에서는 반대다.** phone(8kHz)에서 turbo 8.1% 대 small-ko 28.6% — **3.5배**다.
정보가 적은 입력에서는 큰 모델의 여유가 결정적이다.

`steja/whisper-small-korean`은 이름이 오해를 부른다 — 실제로는 large-v2(1543M)다. 쓰지 않았다.

## 그래서 미결로 남은 질문

**홈캠 오디오는 kspon에 가까운가, phone에 가까운가?** 이 답에 따라 모델 선택이 정반대가 된다.

| 홈캠이 이쪽이면 | 최선 |
|---|---|
| kspon (깨끗한 근접 대화) | `small-ko` — 6.2% 대 turbo 11.8% |
| phone (저음질·원거리) | `turbo` — 8.1% 대 small-ko 28.6% |

**실제 클립 하나(22초, 정답 47자)는 phone 패턴을 따랐다** — turbo 12.8%, small-ko 21.3%.
표본이 47자뿐이라 근거로 쓸 수 없지만, 홈캠이 원거리 마이크라는 점과 방향이 맞는다.
**홈캠 녹음 정답지가 필요하다** (4부 1번 참조).

## 양자화 종류를 고른다

`small-ko`를 종류별로 만들어 zeroth 낭독(정답 1361자)에서 잰 값이다.

| 종류 | CER | 크기 | 추론(PC CPU 6스레드) |
|---|---|---|---|
| fp16 | 2.9% | 465MB | 79.4초 |
| q8_0 | 2.9% | 252MB | 59.3초 |
| **q5_1 ← 현재 배포** | **2.9%** | **181MB** | 74.5초 |
| q5_0 (2026-07-29 교체 전) | **10.7%** | 167MB | 74.3초 |
| q4_0 | 3.4% | 139MB | 45.5초 |

**정밀도 순서가 깨져 있다.** 4비트(q4_0)가 5비트(q5_0)를 3배 이긴다. 비트 수도 대칭성도
설명하지 못한다(q4_0도 대칭 양자화다) — q5_0의 5비트 패킹(4비트 nibble + 별도 high-bit
워드)이 이 모델과 맞지 않는 것으로 보인다.

**q5_1로 교체했다**(2026-07-29). +14MB에 추론 시간은 같고, 낭독 10.7%→2.9%, 대화
11.5%→11.3%, 전화 37.6%→35.6%로 세 조건 모두에서 나아진다. 손해 보는 조건이 없었다.

**q4_0은 쓰지 마라.** 낭독에서는 좋아 보이지만 8kHz에서 41.0%로 **가장 나쁘다.** 정보가
적은 입력에서 4비트가 먼저 무너진다. "용량을 줄이면서 정확도를 얻는다"는 그림은 쉬운
조건에서만 성립한다.

**q5_0의 격차는 낭독에서만 크다.** 대화·전화에서는 q5_0/q4_0/q5_1이 0.2~2%p 안에 모여
있다. 교체 이득도 낭독에 몰려 있다.

**양자화 자체의 대가는 포맷을 바꿔도 남는다.** small-ko fp32 6.2% → q5_1 11.3%(kspon).
온디바이스로 얻는 정확도가 리더보드 숫자의 절반 수준이라는 뜻이다.

## 상용 API와 비교

[rtzr 벤치마크][rtzr]가 KsponSpeech eval clean으로 상용 API를 측정해 공개했다. 우리가 쓴
것과 같은 데이터셋이다.

| API / 모델 | eval clean CER |
|---|---|
| Return Zero | 6.64% |
| **우리: `small-ko` fp32** | **6.2%** |
| Naver ClovaSpeech | 8.05% |
| AWS Transcribe | 8.58% |
| ETRI | 9.99% |
| **우리: `small-ko` q5_1 (배포 형태)** | **11.3%** |
| Google API v2 | 11.82% |
| **우리: `turbo` fp32** | **11.8%** |
| OpenAI Whisper | 12.06% |
| Deepgram nova-2 | 23.48% |

**우리 turbo 11.8%가 그들의 OpenAI Whisper 12.06%와 0.26%p 안에 들어왔다** — 서로 다른
팀이 다른 코드로 잰 값이 일치한 것이므로 측정 파이프라인의 교차 검증이다.

**"폰에서 상용 API 1위급"이라고 말하면 안 된다.** 6.2%는 fp32 값이고 앱이 배포하는
양자화 형태는 11.3%다. Google·OpenAI 수준이고 Return Zero·Clova보다는 뒤진다.

남은 차이 셋: 표본(그들 3000문장, 우리 1438자), 정규화 규칙(그들은 미공개), 전사 방식
(그들은 철자 우선, 우리가 쓴 미러는 `혼자 가두 돼`처럼 발음 전사로 보인다 — 모델이 표준
철자를 내면 오류로 잡혀 **우리에게 불리**하다).

## 측정 조건

| 공유한 것 | 방법 |
|---|---|
| 오디오 | 파일을 **한 번만** 디코딩해 16kHz 모노 float32 numpy로 만들고 그 배열을 모든 모델에 그대로 넘겼다(8kHz도 여기서 한 번 리샘플). 모델이 파일을 각자 읽으면 디코더가 갈려 입력이 달라진다 |
| 정규화·CER | `normalize()` 하나를 통과했다. 타임스탬프, SenseVoice 태그, AI Hub 태그(`n/` `o/` `(())`), 이중 표기(`(12월)/(십 이 월)` → 철자), 공백·문장부호 제거 후 문자 단위 |
| 집계 | **코퍼스 단위 CER** — 총 편집거리를 총 정답 길이로 나눈다. 클립별 CER의 평균은 짧은 클립에 과도한 가중을 준다(kspon은 평균 3.1초) |
| 하드웨어 | RTX 4050 Laptop(6GB) / CPU 6스레드, 순차 실행 |

**fp32는 GPU, 양자화는 CPU(6스레드)다.** 두 묶음의 추론 시간을 서로 비교하면 안 된다.
양자화 쪽이 앱과 같은 런타임·같은 스레드 수라 폰 시간의 대리 지표로 쓸 수 있다(절대값이
아니라 모델 간 비율만).

**갈린 것 하나** — `SungBeom/whisper-small-ko`는 `language="ko"` 인자를 거부한다(한국어
전용 미세조정이라 generation config가 낡았다). 그 모델만 제작자가 정한 기본 설정으로
돌렸다. 한국어 전용이므로 불리하지 않다.

### 데이터셋

| | zeroth | kspon | phone |
|---|---|---|---|
| 출처 | `Bingsu/zeroth-korean` test (CC BY 4.0) | `DragonLine/ksponspeech_eval_clean` test | AI Hub 저음질 전화망(571) Validation |
| 성격 | 낭독, 근접 마이크 | 2인 자유대화, 스튜디오 | 전화 상담, **8kHz narrow band** |
| 클립 | 28개 (평균 10.7초) | 96개 (평균 3.1초) | 48개 (평균 6.4초) |
| 정답 | 1361자 | 1438자 | 1432자 |
| 한 글자의 무게 | 0.07%p | 0.07%p | 0.07%p |

정답 총량이 셋 다 1400자 안팎이라 표를 나란히 비교할 수 있다.

`kspon089.wav` 1개는 오디오가 깨져 제외했고(97→96), phone에서 `(())`(사람도 알아듣지
못한 구간)가 있는 발화 1개를 제외했다. AI Hub 데이터는 재배포 조건이 있어 저장소에 넣지
않는다(`.gitignore`).

## 한계

| 한계 | 왜 문제인가 |
|---|---|
| **홈캠 오디오가 없다** | 세 데이터셋 중 어느 것이 홈캠을 대변하는지 모른다. 그것이 모델 선택을 정하는데 알 수 없다 |
| **아이 목소리가 없다** | 세 데이터셋 모두 성인 화자다. 홈캠의 주 대상이 빠져 있다 |
| **겹쳐 말하기가 약하다** | kspon은 발화 단위로 잘려 있어 실제 대화의 겹침이 없다 |
| **폰 성능 미측정** | PC CPU 시간은 방향만 알려준다. 실기기(S24) 측정이 필요하다 |
| **phone은 상담 도메인이다** | 8kHz라는 점은 홈캠과 비슷하지만 대화 내용·화자 관계가 다르다 |

---

# 2부. 만드는 절차

모델을 바꾸거나 다시 양자화할 때 쓴다.

## 1. HuggingFace에서 내려받는다

```bash
pip install "huggingface_hub[cli]"
huggingface-cli download SungBeom/whisper-small-ko --local-dir C:\Users\SSAFY\dev\hf-small-ko
```

## 2. GGML로 바꾼다

컴파일러가 필요 없다 — 순수 파이썬이다. 세 번째 인자에는 `openai/whisper` 레포가 들어가는데,
**`pip install openai-whisper` 후 `site-packages`를 주면 된다** (스크립트가 찾는 것은
`<경로>/whisper/assets/mel_filters.npz` 하나다).

```bash
python whisper.cpp/models/convert-h5-to-ggml.py <hf-dir> <site-packages> <out-dir>
```

`<out-dir>/ggml-model.bin`이 나온다 — **487,601,984바이트(465MB), 양자화 안 된 상태.**
출력 폴더는 미리 만들어야 한다(없으면 그냥 죽는다).

## 3. 양자화한다 — PC에서 된다

**예전에는 여기가 함정이었다.** 윈도우에 C++ 컴파일러가 없어 안드로이드용으로
크로스컴파일해 기기에서 돌렸는데, **`winget`으로 컴파일러를 받으면 PC에서 그냥 된다.**

```bash
winget install BrechtSanders.WinLibs.POSIX.UCRT
```

conda의 `m2w64-toolchain`은 gcc 5.3을 주는데 whisper.cpp의 C++17을 못 빌드한다. 위
패키지는 gcc 16.1이다.

```bash
git clone --depth 1 https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build -G "MinGW Makefiles" -DWHISPER_BUILD_EXAMPLES=ON -DBUILD_SHARED_LIBS=OFF
cmake --build build --target whisper-quantize -j
build/bin/whisper-quantize ggml-model.bin ggml-small-ko-q5_1.bin q5_1
```

**실행할 때 gcc의 `bin`을 PATH에 넣어야 한다** — 안 넣으면 런타임 DLL을 못 찾아 아무 출력
없이 죽는다(종료 코드만 남는다).

타입 이름 대신 숫자도 된다. 인자 없이 실행하면 목록이 나온다.

**PC에서 만든 결과는 기기에서 만든 것과 완전히 같다.** 기존 에셋을 PC에서 다시 양자화해
SHA256을 대조했더니 동일했다 — 옛 절차가 틀렸던 게 아니라 더 느렸을 뿐이다(양자화 1초,
`adb` 왕복 없음).

<details>
<summary>안드로이드에서 양자화하는 옛 절차 (참고용)</summary>

```bash
cmake -B build-android \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
  -DBUILD_SHARED_LIBS=ON -DWHISPER_BUILD_EXAMPLES=ON
cmake --build build-android --target whisper-quantize -j

adb push build-android/bin/whisper-quantize /data/local/tmp/
adb push build-android/bin/libwhisper.so /data/local/tmp/
adb push build-android/bin/libggml.so /data/local/tmp/
adb push build-android/bin/libggml-base.so /data/local/tmp/
adb push build-android/bin/libggml-cpu.so /data/local/tmp/
adb push ggml-model.bin /data/local/tmp/
adb shell chmod 755 /data/local/tmp/whisper-quantize
adb shell "cd /data/local/tmp && LD_LIBRARY_PATH=. ./whisper-quantize ggml-model.bin out.bin q5_1"
```

결과를 PC로 가져올 때는 `adb pull`이 앱 비공개 폴더를 못 읽으니 `exec-out`으로 바이트를
그대로 받는다 (파이프에서 개행이 변형되지 않는다):

```bash
adb exec-out run-as <패키지> cat files/out.bin > frontend/assets/models/<이름>.bin
```

**가져온 뒤 크기를 대조하라.** 기기 쪽 `ls -l`의 바이트 수와 정확히 같아야 한다.

</details>

## 4. 저장소의 에셋으로 넣는다

`frontend/pubspec.yaml`의 `assets:`와 `whisper_model.dart`의 `whisperModelAsset` 상수를
**함께** 고쳐야 한다. 파일 이름에 양자화 종류가 들어 있어서, 이름이 바뀌면 기기에 남은
옛 사본을 쓰지 않고 새로 복사한다 — 그래서 이름을 반드시 바꿔야 한다.

```yaml
    - assets/models/ggml-small-ko-q5_1.bin
```

APK에 실제로 들어갔는지 확인:

```bash
unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep ggml-small-ko
```

---

# 3부. 돌리는 방법

## 앱

에셋에 들어 있으므로 **추가 인자가 필요 없다**:

```bash
cd frontend
flutter run --dart-define=API_BASE_URL=https://i15e201.p.ssafy.io
```

첫 실행 때 에셋을 앱 폴더(`getApplicationSupportDirectory`)로 복사한다.

### 다른 모델을 시험할 때

기기에 직접 밀어 넣은 모델을 쓰고 싶으면 에셋을 무시하는 인자를 준다:

```bash
flutter run --dart-define=WHISPER_MODEL_PATH=/data/data/<패키지>/files/<다른모델>.bin
```

기기에 넣을 때는 앱의 **비공개 폴더**에 넣어야 한다.
`/storage/emulated/0/Android/data/<패키지>/files/`에 넣으면 `adb shell`에서는 보이지만
**앱 프로세스에서는 `File().exists()`가 거짓**이다 (Android 11+ 스코프 저장소, FUSE 마운트
이름공간이 달라서다. 실기기에서 확인했다). `run-as`로 파이프해 직접 쓴다:

```bash
adb shell "cat /data/local/tmp/모델.bin | run-as <패키지> sh -c 'cat > files/모델.bin'"
```

`WHISPER_MODEL_PATH`가 가리키는 파일이 없으면 `WhisperTranscriber`가 예외를 던지고, 자막은
"대사를 알아듣지 못했어요"로 강등된다. 자르기·저장은 그대로 된다.

## PC 벤치마크

앱과 같은 런타임(whisper.cpp)·같은 스레드 수로 CER을 재므로, 폰에 올리기 전에 후보를
걸러낼 수 있다.

```bash
conda create -n stt_bench python=3.11 -y
conda activate stt_bench
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu124
pip install -r ai/stt_benchmark/requirements.txt

cd ai/stt_benchmark
python test_run_benchmark.py          # normalize() / read_truth() 점검

python fetch_dataset.py --name zeroth --minutes 5 --out dataset/zeroth
python fetch_dataset.py --name kspon  --minutes 5 --out dataset/kspon
python fetch_dataset.py --name phone  --minutes 5 --out dataset/phone \
  --labels-zip "<AI Hub>/2.Validation/라벨링데이터_230316/VL_D03.zip" \
  --audio-zip  "<AI Hub>/2.Validation/원천데이터_230316/VS_D03.zip"

python run_benchmark.py --dir dataset/zeroth            # 전체
python run_benchmark.py --dir dataset/kspon --only small-ko   # 라벨로 선별
python run_benchmark.py --audio <직접만든클립.m4a>       # 정답은 <이름>_original.txt
```

`test_run_benchmark.py`는 `normalize()`와 `read_truth()`를 검사한다 — **둘 다 조용히
틀려서 CER을 오염시킨 전력이 있으므로 손대면 반드시 돌려라.**

## 속도 (갤럭시 S24)

| 처리 | 시간 |
|---|---|
| 120초 클립 전체 | 168초 |
| 침묵을 빼고 발화 구간만 (`_condense`) | **109초** |

실시간과 비슷한 속도다. 그래서 화면을 붙잡지 않고 백그라운드로 돌린다. 10분 영상이면
10분 걸린다.

**스레드 수는 실측으로 정했다** — 4개 68~73초, 6개 56초로 약 18% 빠르다. 알아듣는 양은
스레드와 무관했다. 값을 바꿀 때는 **같은 영상으로 시간과 글자 수를 함께** 재라.

---

# 4부. 남은 숙제

## 1. 홈캠 녹음 정답지 — 모델 선택의 전제조건

`small-ko`와 `turbo` 중 무엇을 쓸지 정하려면 이것이 필요하다.

**녹음은 실제 홈캠 기기로 한다.** 라즈베리파이/젯슨의 로컬 녹화 경로가 이미 있으니
(`ai/device_agent/local-recording.sh`) 그걸로 찍고 오디오만 뽑는다. 폰으로 녹음하면 마이크
특성이 달라서 실제 입력을 대변하지 못한다.

**30초×10개, 정답 500자 이상.** 정답 총량이 500자면 한 글자의 무게가 0.2%p로 떨어져
순위를 믿을 수 있다(47자 클립에서는 2.1%p였고, 그 때문에 결론이 한 번 뒤집혔다).

**클립에 의도적으로 섞을 것** — 이게 없으면 모든 모델이 CER 낮게 나와서 순위가 안 갈린다.

- 아이 목소리 (최소 2클립) — 세 공개 데이터셋에 없는 조건이다
- 겹쳐 말하기 (최소 2클립)
- 마이크에서 3m 이상 거리 (최소 3클립)
- 배경 TV/음악 소리 (최소 2클립)
- 조용하고 가까운 대조 클립 (1~2개 — 상한선을 보기 위해)

**정답 표기 규칙** — 이걸 안 정하면 CER이 모델 성능이 아니라 표기 방식의 차이를 잰다.

- **말한 단어를 표준 표기로 적는다.** 발음을 흉내내지 않고("머겄는데" 아니라 "먹었는데"),
  말하지 않은 것을 채워 넣지도 않는다. 더듬거나 끊은 것은 끊긴 채로 적는다("그 그러니까"를
  "그러니까"로 줄이지 않는다)
- 문장부호를 쓰지 않는다. 어절 띄어쓰기만 한다
- 알아들을 수 없는 구간은 `[불명]`으로 적는다 — 정규화에서 빠진다
- UTF-8로 저장한다 (UTF-16 BOM도 읽히지만 UTF-8이 안전하다)

파일은 `<이름>.wav`와 `<이름>_original.txt` 짝으로 두고 `run_benchmark.py --dir`로 돌린다.

## 2. 홈캠이 저음질로 판명되면 turbo 검토

정확도 3.5배와 폰에서 3배 느림·3배 큰 에셋(q5_0 574MB)을 견주는 문제가 된다.
`royshilkrot/whisper-large-v3-turbo-korean-ggml`처럼 한국어 미세조정 turbo GGML이 이미
배포돼 있어 후보를 늘릴 수 있다.

## 3. 첫 사용 시 내려받기

설치 용량을 181MiB 줄인다. 이 앱은 이미 MinIO에서 서명된 URL로 영상을 내려받으므로 같은
구조를 쓸 수 있다. 내려받을 경로와 진행률 화면이 필요하다.

에셋 복사가 181MiB를 한 번에 메모리에 올린다는 점도 남아 있다 (Flutter에 에셋을 스트림으로
읽는 API가 없다). 저사양 기기에서 문제가 되면 네이티브 `AssetManager`로 스트리밍해야 한다.

## 4. 실기기 측정

최종 후보만 S24에서 CER·시간·용량을 잰다. 기존 측정치가 모두 S24에서 나왔으므로 같은
기기여야 비교가 성립한다.

**base급 모델로 바꾸는 것은 권하지 않는다** (한국어 정확도가 크게 떨어진다).

---

# 5부. 틀렸던 것들

같은 함정을 다시 밟지 않기 위해 기록한다.

**정답을 읽는 코드가 조용히 망가졌다.** 첫 실행에서 세 모델이 나란히 CER 57.0 / 57.2 /
57.5%로 나왔다. `read_truth()`가 인코딩을 순서대로 시도했는데, UTF-8 한글 파일이 우연히
짝수 바이트면 **UTF-16 디코딩이 예외 없이 "성공"하고 한자 쓰레기를 돌려준다.** NUL 검사도
통과한다. **위험한 이유는 실패가 아니라 그럴듯한 숫자로 나왔다는 점이다** — CER 57%는
"모델이 한국어를 잘 못하네"로 읽힌다. 유일한 단서는 독립적인 세 모델이 소수점 차이로 같은
값을 냈다는 것이었다. 지금은 UTF-16을 **BOM으로만** 판별하고, 테스트가 **전제 자체도
검증한다**(시험 문장이 짝수 바이트가 아니면 실패로 만든다 — 처음 쓴 문장이 홀수 바이트여서
아무것도 검사하지 못했다).

**클립 하나로 낸 결론이 뒤집혔다.** 실제 클립(정답 47자)으로 "원본 turbo가 미세조정 small을
이겼다"고 적었는데, kspon 1438자에서는 반대였다. 47자에서 한 글자는 CER 2.1%p다. 다만
phone 결과를 보면 그 클립의 turbo 우세가 우연은 아니었다 — **표본이 작았던 것과 도메인이
달랐던 것이 겹쳐 있었다.**

**양자화 원인을 두 번 잘못 짚었다.** 처음엔 "문맥 누출"이라 했는데 `no_context`는 이미
기본 `True`였다. 다음엔 "앱 파일이 손상됐다"고 했는데 PC에서 다시 양자화한 결과가
SHA256까지 같았다. 진짜 원인은 q5_0 포맷 자체였고, 그것을 가린 것은 **같은 whisper.cpp
안에서 fp16과 q5_0을 나란히 재는 것**이었다(런타임 차이와 양자화 손실을 분리하는 유일한
방법이다).

[rtzr]: https://github.com/rtzr/Awesome-Korean-Speech-Recognition
