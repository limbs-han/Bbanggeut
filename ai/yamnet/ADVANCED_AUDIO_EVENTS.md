# 심화 오디오 이벤트 설계와 실행

이 문서는 웃음 MVP에 연속 박수와 사용자 지정 호출명을 추가하는 Device/AI
구현 기준을 설명한다. 기능은 기본값이 꺼져 있으며 Jetson 자동 배포는 하지 않는다.

## 연속 박수

연속 박수 판정은 두 단계를 모두 통과해야 한다.

- YAMNet의 `Clapping`, `Applause` 계열 점수가 임계값 이상이어야 한다.
- 1.44초 분석 구간에서 서로 분리된 충격음 onset이 3개 이상이어야 한다.
- 박수 양성 구간이 기본 2회 연속되고 최소 0.4초 유지되어야 한다.
- 양성 구간 사이가 0.75초보다 벌어지면 진행 상태를 초기화한다.
- 이벤트 발생 후 12초 동안 새로운 박수 이벤트를 만들지 않는다.

이 방식은 단일 충격음이나 문 닫는 소리를 박수로 오인하는 문제를 줄이기 위한
운영 규칙이다. 정확한 임계값은 BRIO 100 현장 데이터로 다시 보정한다.

```bash
YAMNET_CLAP_ENABLED=true
YAMNET_CLAP_THRESHOLD=0.30
YAMNET_CLAP_CONSECUTIVE=2
YAMNET_CLAP_REQUIRED_ONSETS=3
YAMNET_CLAP_MIN_ACTIVE_SECONDS=0.4
YAMNET_CLAP_MAX_GAP_SECONDS=0.75
YAMNET_CLAP_COOLDOWN=12
```

## 웃음과 박수 병합

동일 유형의 반복 이벤트는 `EVENT_MERGE_GAP_SECONDS`의 기존 30초 범위에서
병합한다. 웃음과 박수는 `EVENT_CROSS_TYPE_MERGE_GAP_SECONDS` 안에 발생한
경우에만 하나의 영상으로 병합한다. 코드 기본값은 5초이며, Jetson 실장 시험에서는
모델별 감지 지연을 측정한 뒤 운영 환경에 12초를 적용했다.

```bash
EVENT_MERGE_GAP_SECONDS=30
EVENT_CROSS_TYPE_MERGE_GAP_SECONDS=12
```

12초는 모든 입력 순서에서 병합을 보장하는 값이 아니다. 실장 시험에서 박수 후
웃음 순서는 웃음 감지가 17.735초 늦어 병합되지 않았고, 웃음 감지 후 즉시 박수친
순서는 4.253초 간격으로 병합됐다. 병합 범위를 계속 늘리면 무관한 사건까지 합쳐질
수 있으므로 실제 onset 시각을 활용하는 개선 전까지 이 제한을 운영 문서에
명시한다.

혼합 이벤트의 로컬 상태와 업로드 영수증에는 다음처럼 두 유형을 보존한다.

```json
{
  "eventTypes": ["LAUGHTER", "CLAP"],
  "title": "웃음과 박수가 함께 포착됐어요"
}
```

박수가 먼저 감지되어도 웃음 트리거를 대표 이벤트로 선택한다. 이는 다중 유형
백엔드 계약과 기존 `LAUGHTER` 업로드 계약을 함께 지원하기 위한 호환 정책이다.
백엔드와 앱의 `eventTypes` 지원이 배포된 환경에서는 종단 검증 후 박수 감지를
활성화할 수 있다. 저장소 기본값은 안전한 단계적 적용을 위해
`YAMNET_CLAP_ENABLED=false`를 유지한다.

## 사용자 지정 호출명

호출명은 화자 인증 기능이 아니다. 누구의 목소리든 등록된 문구를 말하면 로컬
ASR 결과와 문구를 비교한다.

- 사용자는 호출명 텍스트와 발음 샘플을 함께 등록한다.
- 원본 음성 샘플과 체크섬은 Jetson 로컬 프로필에만 저장한다.
- 샘플은 발음 확인 및 평가 데이터로만 사용하며 화자 생체 템플릿을 만들지 않는다.
- 실제 판정은 로컬 Faster-Whisper의 텍스트 결과를 사용한다.
- ASR 모델은 미리 내려받은 로컬 디렉터리만 허용하고 런타임 다운로드를 금지한다.
- 진단 모드를 켜지 않으면 전체 대화 transcript를 파일에 저장하지 않는다.

로컬 프로필을 만든다.

```bash
python3 wake_name_profile.py register \
  --profile-dir ~/.local/share/william-james/wake-name \
  --phrase "윌리엄 제임스" \
  --locale ko-KR \
  --sample ~/wake-name-sample-1.wav \
  --sample ~/wake-name-sample-2.wav

python3 wake_name_profile.py validate \
  --profile-dir ~/.local/share/william-james/wake-name
```

Faster-Whisper는 YAMNet 환경과 분리한다.

```bash
python3 -m venv ~/venvs/wake-name
~/venvs/wake-name/bin/python -m pip install \
  -r requirements-wake-name.txt
```

모델은 PC에서 준비해 Jetson의 `~/ai_models/faster-whisper-small` 같은 로컬
경로로 전달한다. Jetson CPU·GPU 사용량을 벤치마크한 뒤
`WAKE_NAME_ASR_DEVICE`와 `WAKE_NAME_ASR_COMPUTE_TYPE`을 정한다.

```bash
WAKE_NAME_ENABLED=true
WAKE_NAME_PROFILE_DIR="$HOME/.local/share/william-james/wake-name"
WAKE_NAME_MODEL_DIR="$HOME/ai_models/faster-whisper-small"
WAKE_NAME_THRESHOLD=0.82
WAKE_NAME_COOLDOWN=12
WAKE_NAME_ASR_DEVICE=cpu
WAKE_NAME_ASR_COMPUTE_TYPE=int8
```

로컬 트리거는 `schemaVersion: 1.1`을 사용하고 `type`을 `LAUGHTER`,
`CLAP`, `WAKE_WORD` 중 하나로 기록한다. 같은 유형은 30초 범위에서 병합하고,
`LAUGHTER`와 `CLAP`만 설정된 교차 유형 범위에서 병합한다. `WAKE_WORD`는 다른 소리와
교차 병합하지 않는다.

## 혼합 평가 데이터

웃으면서 박수치는 샘플은 `laughter-with-clap` 조건으로 등록한다. 웃음 모델
평가에서는 `laughter`, 박수 평가에서는 `consecutive-clap` 양성인 다중 라벨
샘플이다. 깨끗한 웃음과 박수 샘플을 대체하지 않고 validation과 test에 각각
5개씩 추가한다.

## 로컬 검증

```bash
python3 -m unittest \
  test_audio_event_detection \
  test_audio_event_trigger \
  test_wake_name_profile \
  test_mqtt_event_publisher

python3 -m unittest test_segment_clip_uploader
```

Jetson에서는 기능 활성화 전에 진단 JSONL로 오탐과 미탐을 먼저 측정한다. 모델,
프로필 또는 Backend 계약이 준비되지 않은 상태에서 운영 서비스 설정을 켜지 않는다.
