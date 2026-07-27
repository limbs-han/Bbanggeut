# AI 파트 2026-07-26 야간 작업 및 2026-07-27 인수인계

> 작성 시각: 2026-07-27 KST  
> 대상 장치: NVIDIA Jetson Orin Nano 8GB  
> 회사 목표 장치: Logitech BRIO 100  
> 현재 집 시험 장치: 일반 USB 웹캠·마이크  
> 관련 문서: [전체 규격](./AI_EDGE_INTEGRATION_SPEC.md), [이벤트 녹화 절차](./LAUGHTER_EVENT_RECORDING_RUNBOOK.md), [직전 진행 기록](./AI_DAILY_PROGRESS_2026-07-24.md)

이 문서는 코드 구현, Jetson 실기 검증과 아직 남은 서버·앱 검증을 구분한다.
실제 기기 ID, 토큰, 등록 코드와 인증정보는 기록하지 않는다.

## 1. 한 줄 요약

> 큰 웃음용 MVP 설정과 디스크 기반 전후 60초 클립을 운영 릴리스로 배포하고,
> HTTP 409 영구 실패의 반복 재시도를 차단했으며, 실제 409 원인이 미등록
> 기기임을 확인했다. 동시에 명확한 웃음을 YAMNet이 놓친 사례를 정답 데이터로
> 보존하고 반복 가능한 평가 데이터 도구까지 Jetson에서 검증했다.

## 2. 이번 작업이 향한 다음 단계

이번 작업의 목적은 최소 MVP의 다음 흐름을 완성할 수 있는 상태를 만드는 것이었다.

```text
공유 RTSP
  → YAMNet 웃음 감지
  → 전후 60초 MP4
  → 서버 업로드
  → 앱 이벤트 영상 조회·편집·다운로드
```

Jetson 내부의 클립 생성과 실패 안전성은 확인했다. 서버 업로드 성공 이후
앱 조회·편집·다운로드까지는 기기 claim이 필요하여 회사에서 이어간다.

## 3. 종료 시점의 Jetson 상태

| 항목 | 현재 상태 |
| --- | --- |
| 활성 릴리스 링크 | `/home/ssafy/ai_releases/20260727_004322_laughter_eval` |
| 롤백 릴리스 | `/home/ssafy/ai_releases/20260726_234500_upload_safety` |
| 릴리스 SHA-256 | `e2a51803970fc65d10d6e470da449dd798412052d70895e0bac7272c648ccf44` |
| 릴리스 검증 | YOLO 27개 + YAMNet 17개 = 총 44개 PASS |
| 현재 오디오 설정 | `plughw:CARD=Camera,DEV=0` |
| 회사에서 복원할 설정 | `plughw:CARD=B100,DEV=0` |
| 로컬 RTSP | `main`, `ai` 모두 H.264 1280×720 + AAC 48kHz mono |
| 상시 녹화 | 1분 MPEG-TS, Jetson 시험 상한 8GiB |
| 등록 상태 | Operating 인증은 유효하지만 사용자 계정에 미claim |
| 1시간 시험 | **시작하지 않음** |

종료 직전 다음 서비스가 모두 `active`였다.

```text
wj-media-source
wj-mediamtx-local
wj-local-recording
wj-recording-prune.timer
wj-edge-ai-recording
```

`wj-device-agent`도 별도 확인에서 `active/running`, 재시작 0회, MQTT 연결
상태였다. `/home/ssafy/ai` 링크를 새 릴리스로 전환한 뒤 AI 서비스는
재시작하지 않았다. 현재 실행 중인 Python 프로세스는 이전 업로드 안전성
릴리스에서 시작했지만 두 릴리스의 운영 AI 코드는 동일하다. 다음 서비스
재시작부터 새 릴리스 경로가 사용된다.

### 3.1 Windows 작업공간 상태

이번 변경은 아직 Git에 stage하거나 commit하지 않았다. 사용자와 팀의
브랜치 정책을 확인한 뒤 별도로 처리한다.

```text
M  AI_EDGE_INTEGRATION_SPEC.md
M  LAUGHTER_EVENT_RECORDING_RUNBOOK.md
M  README.md
M  yamnet/yamnet_laughter_detect_jetson.py
M  yolo/run_edge_ai_recording.sh
M  yolo/segment_clip_uploader.py
M  yolo/test_segment_clip_uploader.py
M  yolo/validate_jetson_release.sh
?? AI_DAILY_PROGRESS_2026-07-27.md
?? yamnet/laughter_eval_dataset.py
?? yamnet/test_laughter_eval_dataset.py
```

릴리스 압축본은 다음 경로에 있다.

```text
C:\Users\SSAFY\Downloads\william-james-ai-laughter-eval-20260727_004322.tar.gz
```

## 4. 수행한 작업과 검증 결과

### 4.1 큰 웃음용 MVP 임시 기준선 배포

운영 후보값을 다음과 같이 명시적으로 설정했다.

| 설정 | 값 |
| --- | ---: |
| aggregation | `mean` |
| threshold | `0.125` |
| consecutive | `3` |
| gain | `1.5` |
| cooldown | `12초` |

집 웹캠 환경의 분리 진단에서는 일반 말소리 46개 표본 중 판정 0회,
큰 웃음 시험에서는 실제 판정 1회를 확인했다. 이 값은 큰 웃음용 최소
MVP 후보이며 작은 웃음 지원이나 최종 BRIO 정확도를 의미하지 않는다.

### 4.2 HTTP 업로드 실패 안전성 구현

`yolo/segment_clip_uploader.py`에 다음 동작을 구현했다.

- HTTP 409를 포함한 영구 4xx는 재시도하지 않는다.
- `408`, `425`, `429`, `5xx`와 네트워크 오류만 지수 백오프로 재시도한다.
- 최초 재시도 간격은 5초, 최대 간격은 300초다.
- 영구 실패 시 `<eventId>.upload-blocked.json`을 원자적으로 생성한다.
- Trigger와 MP4를 삭제하지 않고 보존한다.
- 응답 본문은 최대 2,048자로 제한한다.
- 로그의 URL에서 query, fragment와 인증정보를 제거한다.
- 차단 마커가 있으면 같은 프로세스와 서비스 재시작 후 모두 건너뛴다.

Jetson 릴리스 테스트에서 관련 테스트를 포함한 전체 44개가 통과했다.

### 4.3 전후 60초 MP4와 HTTP 409 실제 검증

YAMNet 정확도 문제와 업로드 경로를 분리하기 위해 수동 검증 Trigger를
사용했다. 생성된 이벤트 영상은 다음과 같았다.

| 항목 | 결과 |
| --- | --- |
| 길이 | `120.030초` |
| 영상 | H.264, 1280×720 |
| 음성 | AAC, 48kHz, mono |
| 크기 | `39,461,294 bytes` |
| SHA-256 | `fec4c4e4e57e91b1a483796cd103a1dd2bf396a139edda7b3946b292687696f6` |

서버 응답은 다음 의미였다.

```text
HTTP 409
code=DEVICE_NOT_CLAIMED
등록이 완료된 기기만 영상을 업로드할 수 있음
```

이는 업로더 스키마 오류가 아니라 서버의 정상적인 기기 소유권 검사다.
차단 마커 생성 전후 로그 수가 15초 동안 증가하지 않았고, AI 서비스를
재시작한 뒤에도 해당 이벤트를 처리하지 않았다. Trigger, MP4,
`upload-blocked.json`은 모두 보존돼 있다.

등록 코드는 한 번 발급했지만 앱에서 claim하지 않았고 이미 만료됐다.
코드 값은 문서에 남기지 않는다.

### 4.4 운영 웃음 누락 원인 분석

운영 서비스에서 명확하게 웃은 두 번의 시험 모두 이벤트가 생성되지 않았다.
RTSP와 프로세스 상태는 정상이었으므로 동일 설정으로 진단 JSONL을 수집했다.

| 구간 | 웃음 mean 최고점 | RMS 최고점 | 최대 연속 양성 |
| --- | ---: | ---: | ---: |
| 웃기 전 | `0.012290` | `0.004806` | 0 |
| 실제 웃음 | `0.008764` | `0.257126` | 0 |
| 웃은 뒤 | `0.020007` | `0.157422` | 0 |

실제 웃음은 충분히 크게 녹음됐지만 YAMNet은 주로 `Speech`,
`Chicken, rooster`, `Rustle`로 분류했다. 웃음 점수보다 비웃음 구간
점수가 높으므로 threshold를 `0.008` 수준으로 낮추면 이 웃음보다
잡음을 먼저 감지한다. 따라서 이번 사례는 threshold 조정 문제가 아니라
YAMNet 기본 클래스 분류의 false negative다.

운영값을 즉시 낮추지 않고 YAMNet 임베딩 기반 커스텀 분류기를 별도
정확도 Task로 유지한다.

### 4.5 첫 번째 평가 데이터 확정

상시 녹화 세그먼트에서 누락된 웃음을 삭제 전에 보존했다.

```text
/home/ssafy/ai_datasets/laughter_eval/
└── home_webcam/
    └── false_negative_20260726T150717Z/
        ├── source_segment.ts
        ├── context.mp4
        ├── audio_16k_mono.wav
        ├── waveform.png
        ├── yamnet_diagnostics.jsonl
        ├── operator_window.txt
        └── metadata.json
```

| 항목 | 결과 |
| --- | --- |
| 라벨 | `laughter` |
| 정답 구간 | WAV 기준 `4.5~10.5초` |
| 라벨 상태 | `verified` |
| 녹음 품질 | `clear` |
| 기존 모델 결과 | `false_negative` |
| 캡처 장치 | 집의 일반 USB 웹캠 |
| BRIO 최종 지표 포함 | 아니오 |

카탈로그도 생성했다.

```text
/home/ssafy/ai_datasets/laughter_eval/catalog.json
/home/ssafy/ai_datasets/laughter_eval/catalog.csv
/home/ssafy/ai_datasets/laughter_eval/catalog.md
```

### 4.6 평가 데이터 CLI 구현

새 파일:

```text
yamnet/laughter_eval_dataset.py
yamnet/test_laughter_eval_dataset.py
```

지원 명령:

| 명령 | 역할 |
| --- | --- |
| `create` | MPEG-TS에서 MP4, 16kHz mono WAV, waveform과 metadata 생성 |
| `finalize` | 실제 재생 후 정답 구간을 `verified`로 확정 |
| `validate` | 스키마, 파일 크기와 SHA-256 검사 |
| `catalog` | 전체 샘플을 검사하고 JSON·CSV·Markdown 목록 생성 |

신규 테스트 8개를 추가했고 기존 YAMNet 테스트와 합쳐 17개가 Jetson에서
통과했다. README, 전체 규격과 이벤트 녹화 런북에도 데이터 분리·라벨 검토
원칙을 반영했다.

## 5. 완료·부분 완료·미검증 상태

| 항목 | 상태 | 근거 또는 남은 일 |
| --- | --- | --- |
| 큰 웃음용 MVP 설정 코드 | **구현 완료** | `mean/0.125/3`, 환경변수 지원 |
| 집 웹캠 일반 말소리 무판정 | **Jetson 검증 완료** | 46개 표본, 판정 0회 |
| 집 웹캠 큰 웃음 판정 | **부분 검증** | 한 시험은 성공했지만 운영 재시험 두 번 누락 |
| 디스크 기반 전후 60초 MP4 | **Jetson 검증 완료** | 120.030초 H.264/AAC |
| 영구 4xx 차단과 재시작 후 skip | **Jetson 검증 완료** | 409 마커·파일 보존·무재시도 |
| 서버 업로드 성공 | **미검증** | 기기 claim 필요 |
| 앱 이벤트 영상 조회 | **미검증** | 서버 업로드 성공 이후 확인 |
| 앱 비파괴 편집·다운로드 | **미검증** | 프론트·백엔드 종단 연결 필요 |
| 평가 데이터 CLI | **Jetson 검증 완료** | 총 44개 릴리스 테스트 PASS |
| AI-07 평가 데이터 수집 | **부분 검증** | 표준 도구와 샘플 1개, BRIO 데이터 부족 |
| 작은 웃음 개선 분류기 | **다음 작업** | 임베딩 데이터셋·학습·비교 필요 |
| AI-06 공식 1시간 시험 | **미검증** | 오늘 밤 시작하지 않음 |
| SG90 두 축 실제 제어 | **미검증** | PCA9685·외부 5V·실물 보정 필요 |

## 6. 내일 재개 순서

### P0-1. 회사에서 BRIO 100 입력 복원

현재 집 웹캠용 `Camera` 설정을 회사의 `B100`으로 되돌린다.

```bash
echo "=== DEVICES ==="
lsusb
cat /proc/asound/cards
ls -l /dev/video* 2>/dev/null

backup="/etc/william-james/device-agent.env.bak.return-to-brio.$(date +%Y%m%d_%H%M%S)"

sudo cp -a \
  /etc/william-james/device-agent.env \
  "$backup"

sudo sed -i \
  's|^AUDIO_DEVICE=.*|AUDIO_DEVICE=plughw:CARD=B100,DEV=0|' \
  /etc/william-james/device-agent.env

sudo systemctl restart wj-media-source
sleep 8

systemctl show wj-media-source \
  -p ActiveState \
  -p SubState \
  -p Result \
  -p NRestarts

for path in main ai; do
  ffprobe -v error \
    -rtsp_transport tcp \
    -show_entries stream=index,codec_type,codec_name,width,height,sample_rate,channels \
    -of compact=p=0:nk=1 \
    "rtsp://127.0.0.1:8554/homecam/$path"
done
```

BRIO 복원 후 `wj-edge-ai-recording`을 한 번 재시작하면 새 활성 릴리스가
운영 프로세스에도 적용된다.

```bash
sudo systemctl restart wj-edge-ai-recording
sleep 10

systemctl is-active \
  wj-media-source \
  wj-mediamtx-local \
  wj-local-recording \
  wj-recording-prune.timer \
  wj-edge-ai-recording
```

### P0-2. 앱에서 기기 claim

앱의 기기 등록 화면이 준비된 뒤에만 새 일회용 코드를 발급한다.

```bash
sudo -u williamjames \
  /opt/william-james/device-agent/registration-button.sh
```

코드는 2분 동안만 유효하며 채팅·문서에 기록하지 않는다. 앱에서 등록한 뒤
기기가 ONLINE이고 현재 사용자가 owner/admin인지 확인한다.

### P0-3. 보존 MP4 재업로드

claim이 성공한 뒤에만 실행한다. 차단 마커를 삭제하지 않고 보관 폴더로 옮기면
업로더가 기존 Trigger와 MP4를 재사용한다.

```bash
event_root="$(realpath -e "$HOME/ai_events")"

blocked_file="$(
  find "$event_root" \
    -maxdepth 1 \
    -type f \
    -name '*.upload-blocked.json' \
    -printf '%T@ %p\n' |
  sort -n |
  tail -n 1 |
  cut -d' ' -f2-
)"

test -n "$blocked_file"
blocked_file="$(realpath -e "$blocked_file")"

case "$blocked_file" in
  "$event_root"/*.upload-blocked.json) ;;
  *)
    echo "ERROR: unexpected blocked marker: $blocked_file"
    exit 1
    ;;
esac

archive_dir="$event_root/archive/retry_after_claim_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$archive_dir"
mv -- "$blocked_file" "$archive_dir/"

echo "ARCHIVED_BLOCKED_MARKER=$archive_dir"
```

이후 업로더 로그에서 다음을 확인한다.

```text
POST /api/iot/videos/upload-url 성공
서명 URL PUT 성공
POST /api/iot/videos/complete 성공
<eventId>.uploaded.json 생성
앱 이벤트 영상 목록 반영
```

성공 업로드 후 로컬 MP4와 Trigger가 삭제되는 것은 합의한 “서버 업로드 성공
후 로컬 중복 보관 안 함” 정책에 맞다.

### P1. BRIO 100 평가 데이터 수집

다음 조건을 각각 별도 샘플과 환경 메타데이터로 수집한다.

1. 무음
2. 일반 대화
3. 명확한 큰 웃음
4. 작은 웃음
5. 여러 사람 웃음
6. TV·휴대전화에서 재생한 웃음
7. 기침·재채기·비명
8. 음악과 생활 소음
9. 카메라에서 먼 거리

각 파일은 재생 검토 후 `verified`로 확정하고, BRIO 최종 평가에 사용할
샘플은 `targetDeviceValidation=true`로 기록한다. 개인정보가 담긴 영상·
음성 데이터는 Git에 커밋하지 않는다.

### P2. AI-06 공식 1시간 시험

집 웹캠 예비 1시간 시험은 오늘 시작하지 않았다. 회사에서 BRIO 100을
복원한 뒤 YOLO, YAMNet, 녹화와 업로더를 동시에 1시간 실행한다.

완료 조건:

- 1시간 동안 서비스 중단 없음
- main/ai RTSP 실패 없음
- FPS, 추론 지연, CPU, GPU, RAM, 온도와 전력 기록
- 메모리 지속 증가 여부 판정
- 시험 중 MediaMTX를 한 번 강제로 중단·복구
- YOLO와 YAMNet의 자동 재연결 확인
- 결과 문서 생성

### P3. 작은 웃음 커스텀 분류기

BRIO 평가 샘플이 모인 뒤 YAMNet의 1024차원 임베딩을 입력으로 사용하는
경량 이진·다중 클래스 분류기를 평가한다. 학습·검증·테스트 사람과 녹음
세션을 분리하여 데이터 누수를 막고, 기존 규칙 방식과 Recall, false alarm,
평균 지연을 같은 테스트 세트에서 비교한다.

## 7. 내일 첫 확인 명령

작업 시작 직후 다음 명령만 먼저 실행한다.

```bash
echo "=== RELEASE ==="
readlink -f "$HOME/ai"

echo "=== SERVICES ==="
systemctl is-active \
  wj-device-agent \
  wj-media-source \
  wj-mediamtx-local \
  wj-local-recording \
  wj-recording-prune.timer \
  wj-edge-ai-recording

echo "=== HOME/CURRENT AUDIO CONFIG ==="
sudo grep -E \
  '^(CAMERA_DEVICE|AUDIO_DEVICE|YAMNET_SCORE_AGGREGATION|YAMNET_THRESHOLD|YAMNET_CONSECUTIVE|YAMNET_GAIN)=' \
  /etc/william-james/device-agent.env

echo "=== DATASET ==="
"$HOME/venvs/yamnet/bin/python" \
  "$HOME/ai/yamnet/laughter_eval_dataset.py" catalog \
  --dataset-root "$HOME/ai_datasets/laughter_eval"

echo "=== BLOCKED EVENT ARTIFACTS ==="
find "$HOME/ai_events" \
  -maxdepth 1 \
  -type f \
  \( -name '*.trigger.json' -o \
     -name '*.mp4' -o \
     -name '*.upload-blocked.json' \) \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %f\n' |
sort
```

## 8. Jira 상태 제안

| Jira Task | 권장 상태 | 댓글 요약 |
| --- | --- | --- |
| 큰 웃음용 MVP 기준선 | **In Review** | 집 환경 speech 무판정·큰 웃음 1회 성공, 운영 누락 사례 존재 |
| 전후 60초 이벤트 MP4 | **Done** | 120.030초 H.264/AAC 실기 검증 |
| HTTP 409 반복 재시도 방지 | **Done** | 차단 마커, 보존, 실행 중·재시작 후 skip 실기 검증 |
| 서버 업로드·READY | **Blocked** | 앱에서 기기 claim 후 재개 |
| AI-07 평가 데이터 기반 | **Done** | CLI, 8개 신규 테스트, 검증 샘플·카탈로그 생성 |
| AI-07 BRIO 데이터 수집 | **To Do** | 회사 BRIO 환경에서 조건별 수집 |
| AI-06 공식 1시간 시험 | **To Do** | 오늘 시작하지 않음 |
| 작은 웃음 커스텀 분류기 | **To Do** | BRIO 데이터 확보 후 시작 |
| SG90/PCA9685 실제 제어 | **To Do** | 별도 5V 전원과 실물 보정 필요 |

## 9. 남아 있는 위험과 주의사항

- 현재 집 웹캠 데이터는 BRIO 최종 정확도 결과로 사용하면 안 된다.
- threshold를 낮춰 이번 false negative를 억지로 잡으면 잡음 오탐이 먼저
  증가한다.
- 평가 데이터에는 사적인 영상과 음성이 포함되므로 Git, 팀 메신저와 공개
  저장소에 올리지 않는다.
- `source_segment.ts`는 순환 녹화 삭제와 분리해 평가 데이터 폴더에 복사했다.
- 보존된 수동 이벤트는 실제 사용자 웃음 감지 이벤트가 아니라 업로드 경로
  검증용이다.
- `Rolling clip pending`이 매초 출력돼 로그가 많지만 후행 세그먼트를 기다리는
  정상 상태다. 추후 rate limit을 적용할 수 있다.
- 앱 claim 전에는 차단 마커를 옮기지 않는다.
- 등록 코드는 필요할 때 한 번만 발급하고 2분 내 사용한다.
- 1시간 시험을 수행하지 않았으므로 AI-06을 완료 처리하지 않는다.

## 10. 팀 메신저 공유용 요약

> 야간 작업에서 큰 웃음용 MVP 설정(`mean/0.125/3`)과 디스크 기반 전후
> 60초 클립 경로를 새 릴리스로 배포했고 Jetson 총 44개 테스트를 통과했습니다.  
> 수동 검증 이벤트로 120.030초 H.264/AAC MP4 생성을 확인했습니다.  
> 기존 HTTP 409의 원인은 `DEVICE_NOT_CLAIMED`였고, 영구 4xx 차단 마커와
> 파일 보존 및 서비스 재시작 후 무재시도까지 확인했습니다.  
> 앱 기기 claim과 서버 업로드 성공·앱 조회는 회사에서 이어갑니다.  
> 명확한 웃음을 두 번 놓친 사례를 분석한 결과 오디오는 정상이지만 YAMNet
> 분류 점수가 낮아 threshold 조정으로 해결할 수 없었습니다.  
> 해당 원본을 `verified` false-negative 평가 샘플로 보존하고 생성·확정·
> 무결성 검사·카탈로그 CLI와 신규 테스트 8개를 추가했습니다.  
> 집 웹캠 데이터는 BRIO 최종 지표에서 제외하며, 내일 BRIO 입력 복원 후
> 조건별 데이터 수집과 공식 1시간 시험을 진행할 예정입니다.  
> 오늘 밤 1시간 시험은 시작하지 않았습니다.
