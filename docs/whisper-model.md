# whisper 모델 — 무엇을 쓰고 어떻게 만드나

`features/stt`는 앱에 담긴 whisper.cpp 모델로 전사한다.

**모델은 저장소에 있다** — `frontend/assets/models/ggml-small-ko-q5_0.bin`
(175,209,680바이트, 약 167MiB). 받아서 빌드하면 바로 돈다. 이 문서는 **그 파일을 다시
만드는 절차**다 (모델을 바꾸거나 다시 양자화할 때 필요하다).

앱은 첫 실행 때 이 에셋을 앱 폴더로 복사해서 쓴다 (`whisper_model.dart`) — whisper.cpp는
네이티브에서 파일 경로를 열기 때문에 APK 안에 압축된 에셋을 직접 읽을 수 없다.

**대가**: 저장소가 약 167MiB 커지고 히스토리에 영구히 남는다. 설치 용량도 그만큼 늘어난다
(디버그 APK 366MB — Banuba SDK가 이미 무겁다). 팀 결정으로 받아들였다.

## 무엇을 쓰나

**`SungBeom/whisper-small-ko`를 q5_0으로 양자화한 것.** 465MB → 167MiB.

왜 이걸 골랐나 — **한국어 미세조정이 모델 크기보다 중요했다.**

| 모델 | CER | 비고 |
|---|---|---|
| `SungBeom/whisper-small-ko` (q5_0) | **0.0%** | 정답을 아는 TTS 클립. 채택 |
| 미세조정 small | 6.5% | 다른 한국어 벤치마크 |
| 원본 large-v3 | 11.1% | 크기가 6배인데 더 나쁘다 |

`steja/whisper-small-korean`은 이름이 오해를 부른다 — 실제로는 large-v2(1543M)다. 쓰지 않았다.

실기기(갤럭시 S24)에서는 띄어쓰기 오류 몇 개, 엄마/아빠 혼동 1회, "being" 환청 1회가
있었고 그 외에는 거의 정확했다.

## 만드는 절차

### 1. HuggingFace에서 내려받는다

```bash
pip install "huggingface_hub[cli]"
huggingface-cli download SungBeom/whisper-small-ko --local-dir C:\Users\SSAFY\dev\hf-small-ko
```

### 2. GGML로 바꾼다

```bash
cd C:\Users\SSAFY\dev\whisper.cpp
python models/convert-h5-to-ggml.py C:\Users\SSAFY\dev\hf-small-ko . C:\Users\SSAFY\dev\ggml-out
```

`ggml-out/ggml-model.bin`이 나온다 — **487,601,984바이트(465MB), 양자화 안 된 상태.**

### 3. 양자화한다 — 여기가 함정이다

윈도우에 C++ 컴파일러가 없으면 `whisper-quantize`를 PC에서 빌드할 수 없다.
**안드로이드용으로 크로스컴파일해서 기기에서 돌리는 편이 빠르다.**

```bash
cd C:\Users\SSAFY\dev\whisper.cpp
cmake -B build-android \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 \
  -DBUILD_SHARED_LIBS=ON -DWHISPER_BUILD_EXAMPLES=ON
cmake --build build-android --target whisper-quantize -j
```

`build-android/bin/whisper-quantize`와 `build-android/bin/lib*.so`가 나온다. 기기로 밀어
넣고 돌린다:

```bash
adb push build-android/bin/whisper-quantize /data/local/tmp/
adb push build-android/bin/libwhisper.so /data/local/tmp/
adb push build-android/bin/libggml.so /data/local/tmp/
adb push build-android/bin/libggml-base.so /data/local/tmp/
adb push build-android/bin/libggml-cpu.so /data/local/tmp/
adb push C:\Users\SSAFY\dev\ggml-out\ggml-model.bin /data/local/tmp/
adb shell chmod 755 /data/local/tmp/whisper-quantize
adb shell "cd /data/local/tmp && LD_LIBRARY_PATH=. ./whisper-quantize ggml-model.bin ggml-small-ko-q5_0.bin q5_0"
```

`q5_0` 대신 숫자 `8`도 된다 (`GGML_FTYPE_MOSTLY_Q5_0 = 8`). 다른 종류를 보려면 인자 없이
실행하면 목록이 나온다.

### 4. 저장소의 에셋으로 넣는다

양자화 결과는 폰에 있으므로 PC로 가져와야 한다. 앱 비공개 폴더는 `adb pull`로 못 읽으니
`exec-out`으로 바이트를 그대로 받는다 (파이프에서 개행이 변형되지 않는다):

```bash
adb exec-out run-as <패키지> cat files/ggml-small-ko-q5.bin > frontend/assets/models/ggml-small-ko-q5_0.bin
```

**가져온 뒤 크기를 대조하라.** 기기 쪽 `ls -l`이 알려주는 바이트 수와 정확히 같아야 한다.
한 바이트라도 다르면 조용히 로드에 실패한다.

`frontend/pubspec.yaml`의 `assets:`에 등록되어 있어야 한다:

```yaml
    - assets/models/ggml-small-ko-q5_0.bin
```

APK에 실제로 들어갔는지 확인:

```bash
unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep ggml-small-ko
```

## 앱을 돌리는 방법

에셋에 들어 있으므로 **추가 인자가 필요 없다**:

```bash
cd frontend
flutter run --dart-define=API_BASE_URL=https://i15e201.p.ssafy.io
```

첫 실행 때 에셋을 앱 폴더(`getApplicationSupportDirectory`)로 복사한다. 그다음부터는 있는
것을 쓴다 — 파일 이름에 양자화 종류가 들어 있어서 모델을 바꿀 때 이름만 바꾸면 새로
복사된다.

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

## 속도

갤럭시 S24 기준.

| 처리 | 시간 |
|---|---|
| 120초 클립 전체 | 168초 |
| 침묵을 빼고 발화 구간만 (`_condense`) | **109초** |

실시간과 비슷한 속도다. 그래서 화면을 붙잡지 않고 백그라운드로 돌린다. 10분 영상이면
10분 걸린다.

## 나중에 다시 볼 것

**APK에 넣는 쪽을 골랐다** — 받아서 바로 돌 수 있는 것이 지금 단계에서 더 중요했다.
다음 두 가지는 필요해지면 그때 바꾼다.

1. **첫 사용 시 내려받기** — 설치 용량을 167MiB 줄인다. 이 앱은 이미 MinIO에서 서명된
   URL로 영상을 내려받으므로 같은 구조를 쓸 수 있다. 내려받을 경로와 진행률 화면이 필요하다.
2. **더 작은 양자화** — q4_0으로 하면 약 120MiB가 된다. 한국어 CER이 얼마나 나빠지는지
   재보지 않았다. base 급 모델로 바꾸는 것은 권하지 않는다 (한국어 정확도가 크게 떨어진다).

에셋 복사가 167MiB를 한 번에 메모리에 올린다는 점도 남아 있다 (Flutter에 에셋을 스트림으로
읽는 API가 없다). 저사양 기기에서 문제가 되면 네이티브 `AssetManager`로 스트리밍해야 한다.
