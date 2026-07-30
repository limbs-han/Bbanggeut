# 심화 오디오 이벤트 설계와 실행

이 문서는 웃음 MVP에 연속 박수와 사용자 지정 호출명을 추가하는 Device/AI
구현 기준을 설명한다. 기능은 기본값이 꺼져 있으며 Jetson 자동 배포는 하지 않는다.

## 이벤트 정책

### 연속 박수

- YAMNet의 `Clapping`, `Applause` 계열 점수를 사용한다.
- 한 추론 구간의 충격음만으로 이벤트를 만들지 않는다.
- 기본값은 점수 `0.30` 이상인 구간 2개, 분리된 충격음 2회,
  활동 시간 0.4초 이상이다.
- 양성 구간 간격이 0.75초를 넘으면 연속 횟수를 초기화한다.
- 이벤트 발생 후 12초 동안 같은 이벤트를 다시 만들지 않는다.
- 실제 BRIO 100 데이터셋의 `consecutive-clap`, `speech`, `tv-playback`,
  생활 소음으로 임계값을 다시 정해야 한다.

`run_edge_ai_recording.sh`에서 다음 환경 변수를 사용한다.

```bash
YAMNET_CLAP_ENABLED=true
YAMNET_CLAP_THRESHOLD=0.30
YAMNET_CLAP_CONSECUTIVE=2
YAMNET_CLAP_REQUIRED_ONSETS=2
YAMNET_CLAP_MIN_ACTIVE_SECONDS=0.4
YAMNET_CLAP_MAX_GAP_SECONDS=0.75
YAMNET_CLAP_COOLDOWN=12
```

현재 Backend의 업로드 계약은 `CLAP`을 허용하지 않는다. Backend 기능 브랜치와
앱 표시 기능이 병합되기 전에는 운영 환경에서
`YAMNET_CLAP_ENABLED=false`를 유지한다.

### 사용자 지정 호출명

호출명은 화자 인증 기능이 아니다. 누구의 목소리든 등록한 문구를 말하면 로컬
ASR 결과와 문구를 비교한다.

- 사용자는 호출명 텍스트와 발음 샘플을 함께 등록한다.
- 원본 음성 샘플과 체크섬은 Jetson 로컬 프로필 안에만 저장한다.
- 샘플은 발음 확인 및 평가 데이터로만 사용하며 음성 생체 템플릿을 만들지 않는다.
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

## 트리거와 업로드

로컬 트리거는 `schemaVersion: 1.1`을 사용하고 `type`을
`LAUGHTER`, `CLAP`, `WAKE_WORD` 중 하나로 기록한다. 업로더는 서로 다른 타입을
한 영상으로 병합하지 않는다. 같은 타입의 이벤트만 설정된 병합 간격 안에서
묶는다.

| 타입 | 기본 제목 |
| --- | --- |
| `LAUGHTER` | 웃음이 담긴 순간 |
| `CLAP` | 박수가 시작된 순간 |
| `WAKE_WORD` | 카메라를 부른 순간 |

상황을 분석한 동적 제목과 여러 이벤트 타입을 하나의 세션으로 설명하는 메타데이터는
다음 단계에서 구현한다.

## 로컬 검증

```bash
python3 -m unittest \
  test_audio_event_detection \
  test_audio_event_trigger \
  test_wake_name_profile \
  test_mqtt_event_publisher
```

Jetson에서는 기능 활성화 전에 진단 JSONL로 오탐과 미탐을 먼저 측정한다. 모델,
프로필 또는 Backend 계약이 준비되지 않은 상태에서 운영 서비스 설정을 켜지 않는다.
