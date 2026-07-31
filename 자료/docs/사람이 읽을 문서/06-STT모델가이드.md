# STT 모델 — 무엇을 쓰고, 왜, 어떻게 만드나

`features/stt`는 앱에 담긴 whisper.cpp 모델로 영상의 대사를 전사한다. 이 문서 하나가
**모델 선택 근거·측정 결과·만드는 절차**를 전부 담는다.

## 요약

| | 내용 |
|---|---|
| **최종 채택** | `SungBeom/whisper-small-ko`를 **q5_1**로 양자화 — `frontend/assets/models/ggml-small-ko-q5_1.bin` (190,085,504바이트, 약 181MiB) |
| 교체 이력 | **2026-07-29: q5_0 → q5_1.** q5_0이 낭독에서 CER을 7.8%p 깎고 있었다 |
| 탈락 | **`turbo`**(실기기 3.7배 느림), **q8_0·q4_0·q5_0**(잡음 조건에서 q5_1보다 나쁘다), base급 모델 |
| **보류** | **`SenseVoiceSmall`** — 잡음에서 앞서지만(phone 8.3%p, meeting 2.4%p) meeting 격차가 채택 기준 3%p에 미달. 탈락이 아니다 |

**도메인 판단(2026-07-30):** 홈캠은 깨끗한 근접 대화보다 **잡음이 있는 환경**의 성능이
중요하다. 아이 목소리는 고려 대상에서 뺀다. 그래서 아래 표에서 **phone·meeting 열을
기준으로 읽는다** — 그 판단이 모델 순위를 바꾼다.

**선정 규칙(측정 전에 정했다):** 배포 형태끼리 비교해 **잡음 두 조건 모두에서 3%p 이상**
앞서야 교체한다. 그보다 작으면 런타임 교체 비용을 지불할 근거가 없다. SenseVoice는 phone
8.3%p / meeting 2.4%p로 **한쪽만 넘겨서 보류**가 됐다. 결론을 보고 이 기준을 완화하지
않았다 — 그러면 규칙을 세운 의미가 없어진다.

앱은 첫 실행 때 에셋을 앱 폴더로 복사해서 쓴다 (`whisper_model.dart`) — whisper.cpp는
네이티브에서 파일 경로를 열기 때문에 APK 안에 압축된 에셋을 직접 읽을 수 없다.

**대가**: 저장소가 약 181MiB 커지고 히스토리에 영구히 남는다. 설치 용량도 그만큼 늘어난다
(기존 디버그 APK에는 대용량 상용 편집 SDK도 포함되어 있었다. 해당 SDK는 제거했으며 현재 앱 용량의 큰 비중은 온디바이스 STT 모델이 차지한다). 팀 결정으로 받아들였다.

q5_0 → q5_1 교체로 히스토리에는 **두 파일이 모두 남는다**(약 348MiB). 삭제해도 git
히스토리에서는 사라지지 않는다. 모델을 또 바꿀 일이 잦아지면 "첫 사용 시 내려받기"
(4부 3번)로 전환하는 편이 낫다.

---

# 1부. 측정 결과

2026-07-29. PC에서 같은 조건으로 재고, 앱이 실제로 배포하는 양자화 형태까지 함께 쟀다.
벤치마크 코드는 `ai/stt_benchmark/`.

## 도메인이 순위를 정한다 — 세 데이터셋에서 1등이 다 다르다

| 모델 | zeroth<br>낭독 | kspon<br>대화 | **phone<br>전화 8kHz** | **meeting<br>잡음 회의** |
|---|---|---|---|---|
| `small-ko` fp32 | 2.1% | **6.2%** | 28.6% | **10.3%** |
| `turbo` fp32 | 1.4% | 11.8% | **8.1%** | 9.8% |
| `SenseVoiceSmall` fp32 | **0.4%** | 13.8% | 29.5% | 12.2% |
| `small-ko` q5_0 (교체 전) | 10.7% | 11.5% | 37.6% | 19.4% |
| `small-ko` q4_0 | 3.4% | 11.2% | 41.0% | — |
| `small-ko` q8_0 | 2.9% | — | 37.8% | 16.8% |
| **`small-ko` q5_1 — 최종 채택** | **2.9%** | 11.3% | **35.6%** | **16.3%** |
| `SenseVoiceSmall` int8 | 0.7% | 13.9% | **27.3%** | **13.9%** |

**깨끗한 대화에서는 한국어 미세조정이 크기를 이긴다.** kspon에서 `small-ko`(244M)가
파라미터 3.3배인 `turbo`(809M)를 두 배 차이로 이긴다.

**저음질에서는 반대다.** phone(8kHz)에서 turbo 8.1% 대 small-ko 28.6% — **3.5배**다.
정보가 적은 입력에서는 큰 모델의 여유가 결정적이다. 다만 turbo는 실기기에서 탈락했다.

**잡음 회의(meeting)에서는 격차가 좁다.** small-ko fp32 10.3%, turbo 9.8%로 거의 같다.
phone의 3.5배 격차는 **8kHz라는 특수 조건**에 기댄 것이었다 — 16kHz 잡음에서는 모델
크기의 이점이 크게 줄어든다. 홈캠이 8kHz는 아니므로 meeting이 더 가까운 지표다.

`steja/whisper-small-korean`은 이름이 오해를 부른다 — 실제로는 large-v2(1543M)다. 쓰지 않았다.

## 배포 형태로 다시 읽는다 — 그리고 왜 유지인가

위 표에는 fp32(양자화 없는 GPU 추론)와 배포 형태가 섞여 있다. **실제로 앱에 넣을 수 있는
형태끼리만 골라 잡음 두 조건으로 줄을 세우면 이렇다.**

| 배포 형태 | phone (8kHz) | meeting (잡음 회의) | 크기 | 잡음 조건 추론 |
|---|---|---|---|---|
| `SenseVoiceSmall` int8 | **27.3%** | **13.9%** | 228MB | **8.9초 (15.7배 빠름)** |
| **`small-ko` q5_1 — 최종 채택** | 35.6% | 16.3% | **181MB** | 139.6초 |
| `small-ko` q8_0 | 37.8% | 16.8% | 252MB | 108.4초 |
| `small-ko` q5_0 (교체 전) | 37.6% | 19.4% | 167MB | 130.7초 |
| `turbo` q5_0 | (fp32 8.1%) | (fp32 9.8%) | 547MB | **3.7배 느림** (실기기) |

**SenseVoice가 두 조건 모두에서 앞선다**(8.3%p, 2.4%p). 그런데 **meeting 격차가 채택 기준
3%p에 미달**해서 보류다. phone의 8.3%p는 8kHz라는 특수 조건에 기댄 값이고, 홈캠에 더
가까운 16kHz 잡음(meeting)에서는 2.4%p로 좁혀진다.

**SenseVoice가 이기는 게 아니라 small-ko가 양자화에서 잃는다.**

```
small-ko:    fp32 10.3% → q5_1 16.3%   (+6.0%p)   meeting 기준
SenseVoiceSmall: fp32 12.2% → int8 13.9%   (+1.7%p)
```

**모델 자체 실력은 small-ko가 낫다**(10.3% 대 12.2%). 배포 형태에서 뒤집히는 이유는
small-ko가 양자화에 3.5배 취약하기 때문이다.

**그래서 양자화를 개선하려 했으나 길이 없었다.** q8_0(8비트)이 q5_1(5비트)보다 **나쁘다** —
잡음 두 조건에서 +2.2%p, +0.5%p. 크기는 71MB 더 크다. q4_0도, q5_0도 q5_1보다 나쁘다.
**q5_1이 이 모델의 최적점이고 양자화로 더 얻을 것이 없다.**

정밀도 순서 위반이 이 모델에서 두 번째다(q5_0에 이어 q8_0). 미세조정된 small 모델의
가중치 분포가 표준 양자화 가정과 잘 맞지 않는 것으로 보인다.

**이전 판정을 취소한 기록.** 이 문서는 한때 SenseVoice를 "대화에서 꼴등"이라며 탈락으로
적었다. 그 근거는 kspon(깨끗한 대화) 13.9% 하나였고, 잡음 환경이 중요하다는 도메인 판단이
정해지면서 무효가 됐다. **지금은 탈락이 아니라 보류다.**

### SenseVoice를 다시 볼 조건

**속도 15.7배가 가장 큰 유인이다** — "10분 영상에 10분"이라는 원래 불만을 직접 겨눈다.
아래 셋이 확인되면 3%p 기준을 재검토할 값어치가 있다.

1. **실기기 속도** — PC 값(9~18배)이 폰에서도 유지되는지. sherpa-onnx를 안드로이드용으로
   빌드해 재야 한다. **CPU에서는 GPU 기준 예측이 배신한다** — turbo가 그 예다(아래 참조).
2. **자막 줄 나누기** — CTC라 토큰 타임스탬프만 준다. whisper의 세그먼트를 그대로 자막
   줄로 쓰던 방식을 못 쓴다. `speech_analysis.dart`의 발화 구간 검출을 재사용하면 되지만
   **CER로는 검증되지 않는다** — 눈으로 봐야 한다.
3. **라이선스** — 모델 가중치가 FunASR Model Open Source License Agreement고 상업적 사용
   조항이 회색이다. 채택 전에 협정 전문을 확인해야 한다.

또 런타임 교체(whisper.cpp → sherpa-onnx)가 필요하다. Flutter 패키지
[`sherpa_onnx`](https://pub.dev/packages/sherpa_onnx)가 있고 `timestamps` 배열을 준다.

## turbo는 왜 탈락했나 — 실기기 측정

갤럭시 S24, 120초 오디오(phone 이어붙임), 6스레드, 앱과 같은 디코딩 설정으로 쟀다.

| | small-ko q5_1 | turbo q5_0 |
|---|---|---|
| encode | 22.9초 (5.7초/run) | **151.4초 (37.8초/run)** |
| decode | 22.3초 (444 runs) | 3.2초 (71 runs) |
| **합계** | **49.3초** | **184.2초 (3.7배)** |

**turbo의 "decoder가 4층이라 빠르다"는 장점은 CPU에서 무의미하다.** decode는 실제로 7배
빠르지만(3.2초 대 22.3초) encoder가 6.6배 무거워 전체의 82%를 먹는다. GPU 기준으로 세운
판단이 폰에서 뒤집히는 지점이다.

기존 앱 실측(120초 → 93초)에 3.7배를 적용하면 **10분 영상에 약 29분**이다.
설계 규칙("영상 길이의 2배 이내" = 20분)을 크게 넘는다.

세 축 모두 걸린다.

| 축 | 결과 |
|---|---|
| 속도 | 3.7배. 10분 영상에 약 29분 |
| 용량 | 547MB, 앱이 복사하면 1.1GB. 시험 기기가 이미 99%(여유 4.3GB)였다 |
| 메모리 | 에셋 복사가 파일 전체를 한 번에 올린다(Flutter에 스트림 API 없음). 547MB는 위험하다 |

측정 중 encode가 32.3초 → 37.8초/run으로 17% 느려졌다. 연속 실행이었으니 **발열
스로틀링**으로 보인다 — 실사용에서 10분 영상을 돌리면 더 나빠진다.

**`best_of`로 속도를 벌 수 있다고 봤으나 틀렸다.** `-bo 5`(49.3초)와 `-bo 1`(46.6초)이
거의 같다. temperature=0에서는 whisper.cpp가 디코더를 5개 잡아도 실제로 하나만 쓴다.
디코딩 설정으로 얻을 여지는 없다.

## 양자화 종류를 고른다

`small-ko`를 종류별로 만들어 재봤다. **한 조건만 보면 속는다** — 그래서 낭독과 잡음 두
조건을 함께 놓는다.

| 종류 | zeroth 낭독 | **phone 8kHz** | **meeting 잡음** | 크기 |
|---|---|---|---|---|
| fp16 | 2.9% | — | — | 465MB |
| q8_0 | 2.9% | 37.8% | 16.8% | 252MB |
| **q5_1 ← 최종 채택** | **2.9%** | **35.6%** | **16.3%** | **181MB** |
| q5_0 (2026-07-29 교체 전) | **10.7%** | 37.6% | 19.4% | 167MB |
| q4_0 | 3.4% | 41.0% | — | 139MB |

**q5_1이 모든 조건에서 최선이다.** 낭독에서는 fp16·q8_0과 같고, 잡음 두 조건에서는 단독
1위다. **양자화로 더 얻을 것이 없다.**

**정밀도 순서가 두 번 깨진다.**

- 낭독에서 4비트(q4_0 3.4%)가 5비트(q5_0 10.7%)를 3배 이긴다
- 잡음에서 8비트(q8_0)가 5비트(q5_1)보다 나쁘다 — phone +2.2%p, meeting +0.5%p

비트 수도 대칭성도 설명하지 못한다(q4_0도 대칭 양자화다). 미세조정된 small 모델의 가중치
분포가 표준 양자화 가정과 잘 맞지 않는 것으로 보인다. **그래서 이 모델의 양자화는 추정하지
말고 조건별로 재야 한다** — 이 표가 그 기록이다.

**q4_0과 q8_0은 쓰지 마라.** q4_0은 낭독에서 좋아 보이지만 8kHz에서 41.0%로 가장 나쁘다.
q8_0은 크기가 71MB 더 큰데 잡음 두 조건에서 모두 뒤진다. **"비트를 늘리면 정확해진다"와
"비트를 줄이면 용량이 준다"가 둘 다 이 모델에서는 성립하지 않는다.**

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

| | zeroth | kspon | phone | **meeting** |
|---|---|---|---|---|
| 출처 | `Bingsu/zeroth-korean` test (CC BY 4.0) | `DragonLine/ksponspeech_eval_clean` test | AI Hub 저음질 전화망(571) Validation | **AI Hub 회의 음성(464) Validation** |
| 성격 | 낭독, 근접 마이크 | 2인 자유대화, 스튜디오 | 전화 상담, **8kHz narrow band** | **회의·토론 3~5인, 16kHz, `environment`로 잡음만 골라냄** |
| 클립 | 28개 (평균 10.7초) | 96개 (평균 3.1초) | 48개 (평균 6.4초) | 50개 (평균 6.0초) |
| 정답 | 1361자 | 1438자 | 1430자 | 1636자 |
| 한 글자의 무게 | 0.07%p | 0.07%p | 0.07%p | 0.06%p |

정답 총량이 넷 다 1400~1600자라 표를 나란히 비교할 수 있다.

**meeting은 `environment` 필터가 존재 이유다.** 이 데이터셋은 매체가 방송 위주(공중파·라디오·
인터넷방송·기타녹음)라 발화의 94%가 잡음 표시 없이 깨끗하다. 필터 없이 뽑으면 kspon과 다를
바 없는 측정이 된다. `environment ∈ {잡음, 배경 음악}`으로 골라야 홈캠 조건에 가까워진다.

제외한 것: `kspon089.wav` 1개(오디오 깨짐, 97→96), phone·meeting에서 `(())`(사람도 알아듣지
못한 구간)가 있는 발화 각 1개.

**AI Hub 데이터를 다룰 때 겪은 함정 둘** — 둘 다 예외 없이 조용히 그럴듯한 결과를 낸다.

1. **원천데이터 zip에 UTF-8 플래그가 없다.** `zipfile`이 한글 경로를 cp437로 디코딩해서
   (`인터넷방송` → `└╬┼═│▌╣µ╝█`) 라벨과 짝이 **0/957**이었다. `cp437 → cp949`로 복구하면
   957/957이 맞는다. 못 잡으면 "0개 추출됨"이라는 애매한 실패로 끝난다.
2. **`/(bgm)` `/(noise)` 배경음 표기.** 괄호·슬래시만 지우면 `bgm`이라는 낱말이 정답에
   남는다. 잡음 발화만 골랐으니 47회나 있었고 **정답의 8.7%를 차지했다.** 모든 모델에
   똑같이 걸려서 순위는 안 바뀌지만 절대값이 오염돼 다른 데이터셋과 비교할 수 없게 된다.

**이중 표기 순서가 데이터셋마다 반대다.** phone은 `(12월)/(십 이 월)`로 앞이 철자, meeting은
`(아홉 건의)/(9건의)`로 뒤가 철자다. `fetch_dataset.py`가 추출할 때 철자 쪽을 골라 저장하므로
`normalize()`는 하나를 공유한다 — 정답과 가설이 같은 함수를 통과한다는 원칙을 지키기 위한
설계다.

## 실제 홈캠 클립 — 표본은 작지만 방향은 분명하다

팀이 녹음한 실제 클립(75초, 정답 103자)에서 잰 값이다. **한 글자가 0.97%p라 순위 판정에는
쓸 수 없다** — 아래 q5_0이 q5_1보다 좋게 나온 것은 4글자 차이로 우연이다.

| 모델 | CER | 자모 CER |
|---|---|---|
| **`small-ko` fp32** | **15.5%** | **12.6%** |
| `turbo` fp32 | 17.5% | 13.0% |
| `small-ko` q5_0 | 31.1% | 27.7% |
| **`small-ko` q5_1 (배포본)** | **35.0%** | **30.3%** |
| `SenseVoiceSmall` fp32 | 35.9% | 31.5% |
| `SenseVoiceSmall` int8 | 41.7% | 39.1% |

**읽어낼 것 둘.**

1. **모델 자체 실력은 small-ko가 실제 도메인에서도 1위다**(15.5%, turbo 17.5%보다 낫다).
   공개 데이터셋 넷에서 본 것과 일치한다.
2. **양자화가 CER을 두 배 이상 깎는다** — fp32 15.5% → q5_1 35.0%(**+19.5%p**). meeting에서
   +6.0%p였던 손실이 실제 도메인에서 더 크게 나타난다. **앱이 실제로 얻는 정확도는 모델
   실력의 절반 이하다.**

2번이 남은 개선의 핵심 표적이다. 양자화 포맷으로는 이미 최적점(q5_1)이므로, 이 손실을
줄이려면 **모델을 잡음 데이터로 미세조정해 양자화에 견고하게 만드는 것**밖에 남지 않는다
(4부 참조).

`CD`를 세 모델 모두 `CG`로 들었고, `예` 같은 짧은 감탄사는 아무도 잡지 못했다.

### 자모 CER — 발음이 비슷한 오류에 부분 점수를 준다

음절 단위 CER은 종성 하나 차이를 음절 전체 오류로 센다(`것` 대 `거` = 100% 오류). 한국어는
음절 하나가 자모 2~3개라 이 과대평가가 크다. `unicodedata.NFD`로 분해해 재면 `것` 대 `거`가
3분의 1 오류가 된다.

**절대값을 CER과 비교하면 안 된다** — 분모가 2~3배라 항상 낮게 나온다. 모델 간 상대 비교에만
쓴다. 한국어 ASR 평가에서 쓰이는 지표라 특정 데이터셋에 맞춘 조정이 아니다.

**자모 CER은 순위도, 판정도 바꾸지 않았다.** 절대값이 2~5%p 낮아지지만 서열은 그대로다.
meeting에서 핵심 비교를 다시 재봤다.

| 모델 | CER | 자모 CER |
|---|---|---|
| `small-ko` q5_1 | 16.3% | 14.1% |
| `SenseVoiceSmall` int8 | 13.9% | 11.7% |
| **격차** | **2.4%p** | **2.4%p** |

**격차가 두 지표에서 정확히 같다.** 발음 유사 오류를 참작해도 채택 기준 3%p에 미달하므로
**SenseVoice 보류 판정이 유지된다.** 즉 **모델 간 격차는 발음이 비슷한 오류가 아니라
누락·다른 낱말에서 온다** — 홈캠 클립에서 순위가 안 바뀐 것과 같은 결론이다.

## 한계

| 한계 | 왜 문제인가 |
|---|---|
| **홈캠 정답지가 103자뿐이다** | 한 글자가 0.97%p라 순위 판정에 못 쓴다. 30초×10개(500자 이상)가 필요하다 — 절차는 4부 2번 |
| **겹쳐 말하기가 약하다** | kspon은 발화 단위로 잘려 있어 실제 대화의 겹침이 없다. 회의 음성(464)이 이 조건을 메운다 |
| **SenseVoice 폰 성능 미측정** | small-ko와 turbo는 S24에서 쟀다. SenseVoice는 sherpa-onnx를 안드로이드용으로 빌드해야 잴 수 있다 |
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

`<out-dir>/ggml-model.bin`이 나온다 — **487,601,984바이트(465MB), fp16 — 양자화 전 상태.**
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
# requirements.txt에 없는 나머지 — 양자화 CPU 측정(pywhispercpp), SenseVoice(sherpa-onnx),
# zeroth/kspon 내려받기(datasets)에 필요하다
pip install pywhispercpp sherpa-onnx datasets numpy

cd ai/stt_benchmark
python test_run_benchmark.py          # normalize() / read_truth() / to_jamo() 점검

python fetch_dataset.py --name zeroth --minutes 5 --out dataset/zeroth
python fetch_dataset.py --name kspon  --minutes 5 --out dataset/kspon
python fetch_dataset.py --name phone  --minutes 5 --out dataset/phone \
  --labels-zip "<571>/2.Validation/라벨링데이터_230316/VL_D03.zip" \
  --audio-zip  "<571>/2.Validation/원천데이터_230316/VS_D03.zip"

# meeting은 environment 필터가 기본으로 켜져 있다(잡음·배경 음악).
# --environment 반복 지정으로 값을 바꿀 수만 있고 끄는 스위치는 없다 —
# 필터 없이 뽑으면 발화의 94%가 깨끗해서 kspon과 다를 바 없는 측정이 되기 때문이다.
python fetch_dataset.py --name meeting --minutes 5 --out dataset/meeting \
  --labels-zip "<464>/2.Validation/라벨링데이터_260312_add/VL1.zip" \
  --audio-zip  "<464>/2.Validation/원천데이터/VS1.zip"

# 직접 녹음한 파일에서 클립 자르기 (ffmpeg 불필요 — PyAV가 들고 있다)
python prepare_clips.py --input <녹화.mp4> --at 0:15 --at 1:20 \
  --out dataset/homecam --prefix homecam

python run_benchmark.py --dir dataset/zeroth            # 전체
python run_benchmark.py --dir dataset/kspon --only small-ko   # 라벨로 선별
python run_benchmark.py --audio <직접만든클립.m4a>       # 정답은 <이름>_original.txt

# 디코딩 파라미터 A/B — 모델을 바꾸지 않고 얻을 개선이 남았는지 본다.
# 채택선: 모든 조건에서 +0.6%p 이상(한 글자 0.06%p의 10배). 한 조건만 보면 속는다.
python tune_params.py --dir dataset/meeting --dir dataset/phone
```

`test_run_benchmark.py`는 `normalize()`, `read_truth()`, `to_jamo()`(자모 CER)를 검사한다 —
**조용히 틀려서 CER을 오염시킨 전력이 있으므로 손대면 반드시 돌려라.**

## 속도 (갤럭시 S24)

| 처리 | 시간 / 결과 |
|---|---|
| 120초 클립 전체(원본 그대로) | **93초 / 143자** |
| 침묵을 빼고 발화 구간만 이어붙임 (폐기) | 75초 / 65자 — 문맥이 끊겨 인식률 붕괴 |

침묵 제거 경로는 빨랐지만 버렸다 — 발화 구간만 잘라 이어붙이면 문맥이 끊겨 알아듣는
양이 절반 아래로 떨어진다. 지금은 원본 전체를 그대로 넘기고, 발화 구간 검출은 말소리
유무 판정(조용한 영상 건너뛰기)에만 쓴다.

실시간보다 조금 빠른 속도다(120초 영상에 93초). 그래서 화면을 붙잡지 않고 백그라운드로
돌린다. 10분 영상이면 8분 안팎 걸린다.

**스레드 수는 실측으로 정했다** — 4개 68~73초, 6개 56초로 약 18% 빠르다. 알아듣는 양은
스레드와 무관했다. 값을 바꿀 때는 **같은 영상으로 시간과 글자 수를 함께** 재라.

---

# 4부. 남은 숙제

## 1. 모델 선정은 끝났다 — 남은 개선 경로

**`small-ko` q5_1로 확정.** 양자화는 최적점에 도달했고(q8_0·q4_0·q5_0 전부 열세), turbo는
실기기에서 탈락했다. SenseVoice는 보류다.

남은 개선 경로는 이 순서다.

| 경로 | 상태 | 비고 |
|---|---|---|
| 양자화 개선 | ❌ **닫혔다** | q5_1이 최적점. q8_0·q4_0·q5_0 전부 열세 |
| 디코딩 파라미터 튜닝 | ❌ **닫혔다** (측정 완료) | 아래 참조 |
| 자막 생성 시점 이동 | 미착수 | 지금은 영상을 내려받은 직후(편집 화면 진입 시) 시작한다. 요청 시·충전 중 생성으로 옮겨 모델로 못 얻는 속도를 UX로 흡수하는 카드 |
| SenseVoice 재검토 | 조건 확인 후 | 속도 15.7배가 유인 |
| **양자화 손실 줄이기 (미세조정)** | **가장 큰 표적** | 실제 홈캠 클립에서 fp32 15.5% → q5_1 35.0%(**+19.5%p**). 포맷으로는 최적점이라 남은 길은 **모델을 잡음 데이터로 미세조정해 양자화에 견고하게 만드는 것**이다. AI Hub 데이터 이용 조건 확인 필요. **미세조정 후 GGML 변환·양자화가 되는지 먼저 확인해야 한다** — 안 되면 전부 헛일이다 |

### 디코딩 파라미터로는 얻을 것이 없다 — 재봤다

`tune_params.py`로 잡음 두 조건을 A/B했다. **다섯 설정이 소수점까지 같았다.**

| 설정 | meeting | phone |
|---|---|---|
| 기준 (whisper.cpp 기본값) | 16.3% | 35.6% |
| `suppress_nst=True` | 16.3% | 35.6% |
| `no_speech_thold=0.8` | 16.3% | 35.6% |
| `entropy_thold=3.0` | 16.3% | 35.6% |
| 셋 다 | 16.3% | 35.6% |

**파라미터는 정상 적용됐다** — `get_params()`로 되읽어 확인했다. 적용됐는데 결과가 안
바뀌는 이유는 **이 값들이 temperature fallback 경로에서만 쓰이고, temperature=0에서는
fallback이 트리거되지 않기** 때문이다.

같은 이유로 `best_of`도 무효였다(5→1에서 49.3초→46.6초, CER 동일). 즉 **whisper.cpp의
디코딩 파라미터 대부분은 temperature=0에서 손댈 여지가 없다.** `whisper_ggml_plus`가
파라미터를 노출하지 않아 포크를 고민했는데, **포크할 근거 자체가 사라졌다.**

이건 negative result지만 기록할 값어치가 있다 — 같은 시도를 반복하지 않도록.

**하지 말아야 할 것**: 데이터셋 하나에 맞춘 후처리. CER은 낮아지지만 실제 앱에서 아무것도
개선하지 않고 측정만 망친다.

## 2. 홈캠 녹음 정답지 — 판정이 애매할 때

위 벤치마크로 갈리면 필요 없을 수도 있다. 결과가 애매하면 실물로 확인한다.

**녹음은 실제 홈캠 기기로 한다.** 라즈베리파이/젯슨의 로컬 녹화 경로가 이미 있으니
(`ai/device_agent/local-recording.sh`) 그걸로 찍고 오디오만 뽑는다. 폰으로 녹음하면 마이크
특성이 달라서 실제 입력을 대변하지 못한다.

**30초×10개, 정답 500자 이상.** 정답 총량이 500자면 한 글자의 무게가 0.2%p로 떨어져
순위를 믿을 수 있다(47자 클립에서는 2.1%p였고, 그 때문에 결론이 한 번 뒤집혔다).

**클립에 의도적으로 섞을 것** — 이게 없으면 모든 모델이 CER 낮게 나와서 순위가 안 갈린다.

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

**클립 자르기는 `prepare_clips.py`가 한다.** PC에 ffmpeg가 없어도 된다 — PyAV가 wheel에
ffmpeg를 담고 있어 mp4·mkv·m4a를 가리지 않는다.

```bash
cd ai/stt_benchmark
python prepare_clips.py --input ../../recordings/rec.mp4 \
  --at 0:15 --at 1:20 --at 2:30 --at 4:05 --at 5:40 \
  --out dataset/homecam --prefix homecam
```

`--at`은 여러 번 줄 수 있고 `mm:ss`·`hh:mm:ss`·초를 다 받는다. `--duration`(기본 30초)으로
클립 길이를 바꿀 수 있으며, 1초 미만이 되는 클립과 파일 길이를 넘는 시작점은 건너뛴다.
클립마다 16kHz 모노 wav와 **빈 `_original.txt`**가 짝으로 생긴다. 그 빈 파일에 정답을
적고 돌린다.

```bash
python run_benchmark.py --dir dataset/homecam
```

**30초로 자르는 이유가 하나 더 있다.** 30초를 넘으면 fp32 경로가 long-form 생성으로 넘어가는데,
`small-ko`는 generation config가 낡아 폴백이 둘 필요하다 — `language` 인자를 거부하면 기본
설정으로 재시도하고, 그와 별개로 `return_timestamps`를 거부하면 `chunk_length_s=30` 청킹으로
우회한다. whisper.cpp 경로는 자체 청킹이라 해당 없다. 스크립트가 다 처리하지만, 30초
클립이면 그 경로를 아예 타지 않아 조건이 단순해진다.

## 3. 첫 사용 시 내려받기

설치 용량을 181MiB 줄인다. 이 앱은 이미 MinIO에서 서명된 URL로 영상을 내려받으므로 같은
구조를 쓸 수 있다. 내려받을 경로와 진행률 화면이 필요하다.

에셋 복사가 181MiB를 한 번에 메모리에 올린다는 점도 남아 있다 (Flutter에 에셋을 스트림으로
읽는 API가 없다). 저사양 기기에서 문제가 되면 네이티브 `AssetManager`로 스트리밍해야 한다.

## 4. SenseVoice 실기기 측정

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

**`best_of`로 속도를 3.6배 벌 수 있다고 봤으나 틀렸다.** 앱 실측 168초와 whisper-cli
49.3초의 차이를 `best_of 5` 탓으로 추정했는데, 실제로 재보니 `-bo 5`(49.3초)와
`-bo 1`(46.6초)이 거의 같았다. temperature=0에서는 whisper.cpp가 디코더를 5개 잡아도
하나만 쓴다. **두 값의 차이는 아직 설명되지 않았다** — 오디오 내용이 다르고(발화 밀도),
앱은 타임스탬프를 생성한다. turbo가 탈락해 급하지 않아 남겨뒀다.

**SenseVoice를 성급하게 탈락시켰다.** kspon(깨끗한 대화) 13.9% 하나를 근거로 문서에
"탈락"이라고 적었다. 잡음 환경이 중요하다는 도메인 판단이 정해지자 그 근거가 무효가 됐고,
phone·meeting 배포 형태에서는 오히려 앞섰다. **한 조건의 결과로 후보를 지우면 도메인 판단이
바뀔 때 되돌려야 한다** — 네 조건을 다 재고 나서 판정한 것이 결과적으로 옳았다.

**q8_0에 기대했다가 빗나갔다.** small-ko의 양자화 손실(+6.0%p)을 8비트로 줄일 수 있다고
봤는데, 잡음 두 조건에서 q5_1보다 나빴다. 낭독에서 둘이 같았던 것(2.9%)을 근거로 "잡음에서도
비슷하거나 나을 것"이라 추정한 것이 틀렸다. **양자화 손실은 조건마다 다르게 나타난다** —
q5_0이 낭독에서만 병리적이었던 것과 같은 교훈을 반대 방향으로 다시 배웠다.

[rtzr]: https://github.com/rtzr/Awesome-Korean-Speech-Recognition
