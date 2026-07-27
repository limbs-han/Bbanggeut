# YOLO RTSP 입력·복구 검증 결과

> 검증일: 2026-07-24  
> 대상 장치: NVIDIA Jetson Orin Nano 8GB + Logitech BRIO 100  
> 입력: `rtsp://127.0.0.1:8554/homecam/ai`  
> 검증 코드: 운영 경로와 분리한 `/home/ssafy/ai_task1_trial/yolo`  
> 증거 폴더: `/home/ssafy/ai_validation/yolo_rtsp_20260724_160831`

이 문서는 Jira Task 1의 YOLO RTSP 입력 검증 결과를 기록한다. 격리된
시험판의 기능 통과와 운영 코드 반영 완료를 구분하며, 시험하지 않은
고양이·강아지를 탐지 실패로 판정하지 않는다.

## 1. 검증 목적

기존 운영 YOLO는 UDP 입력으로 실행되고 있었고 최신 프레임 유지·RTSP 자동
재연결 모듈이 운영 폴더에 배포되지 않은 상태였다. 이번 시험의 목적은 다음
기능을 실제 Jetson과 BRIO 100 스트림에서 확인하는 것이었다.

1. YOLO가 로컬 RTSP AI 경로를 직접 입력으로 사용한다.
2. 추론이 입력보다 느려도 오래된 프레임을 계속 쌓지 않는다.
3. 사람을 탐지하고 ByteTrack ID와 자동 구도 목표를 생성한다.
4. 사람이 사라지면 `HOLD`를 거쳐 `HOME`으로 전환한다.
5. MediaMTX를 강제로 중단했다가 복구해도 YOLO가 종료되지 않고 재연결한다.

## 2. 시험 전 선행 조건 복구

BRIO 100의 ALSA 카드 이름이 기존 설정의 `Camera`와 달라 미디어 캡처
서비스가 재시작을 반복하고 있었다. 실제 카드 이름인 `B100`을 확인한 뒤
다음과 같이 수정했다.

```text
CAMERA_DEVICE=/dev/video0
AUDIO_DEVICE=plughw:CARD=B100,DEV=0
```

변경 전 환경 파일은 다음 이름으로 Jetson에 백업했다.

```text
/etc/william-james/device-agent.env.bak.20260724_154643
```

3초 마이크 시험에서 48kHz mono PCM 입력을 확인했고, 이후
`wj-media-source`는 재시작 횟수 0으로 `active/running` 상태가 됐다.
MediaMTX를 시작한 뒤 `main`과 `ai` 두 경로에서 H.264 1280×720 영상과
AAC 음성을 `ffprobe`로 확인했다.

## 3. 배포 안전 방식

운영 폴더에는 기존 YOLO 서비스가 사용 중인 코드가 있었고 최신
`stream_capture.py`가 없었다. 의존 파일 일부만 운영 폴더에 덮어쓰면 서로
다른 버전이 섞일 수 있으므로 다음 격리 경로에 동일 버전 묶음을 배치했다.

```text
/home/ssafy/ai_task1_trial/yolo
```

Jetson에서 다음 사항을 먼저 확인했다.

- `stream_capture.py`와 `yolov8_autoframe_jetson.py`의 SHA-256 일치
- Python 문법 검사 통과
- `test_stream_capture.py` 3개 테스트 통과
- 검증 시작 전 기존 AI 서비스만 안전하게 중지
- 미디어 캡처와 MediaMTX는 계속 실행
- 검증 종료 후 기존 AI 서비스 복구

따라서 이번 결과는 **격리된 시험판 검증 완료**이며 아직 **운영 코드 배포
완료**를 의미하지 않는다.

## 4. Jetson 검증 결과

| 검증 항목 | 결과 | 증거 |
| --- | --- | --- |
| RTSP 최초 연결 | **PASS** | `Video stream connected` |
| 사람 탐지 | **PASS** | 424개 명령 표본에서 사람 관찰 |
| 동시 사람 수 | **PASS** | 최대 4명 |
| ByteTrack ID 생성 | **PASS** | 고유 ID 10개 |
| `TRACKING` | **PASS** | 424개 표본 |
| 탐지 소실 후 `HOLD` | **PASS** | `NO_TARGET_HOLD` 71개 표본 |
| `HOLD` 후 `HOME` | **PASS** | `RETURN_HOME` 56개 표본 |
| 강제 RTSP 중단 감지 | **PASS** | unavailable 로그 5회 |
| 지수 백오프 | **PASS** | 1초 → 2초 → 4초 → 8초 → 10초 |
| RTSP 복구 후 재연결 | **PASS** | reconnected 로그 1회 |
| JSONL 무결성 | **PASS** | 551줄, 잘못된 JSON 0줄 |
| 고양이 탐지 | **NOT TESTED** | 현장에 고양이가 없어 시험 제외 |
| 강아지 탐지 | **NOT TESTED** | 현장에 강아지가 없어 시험 제외 |

### 실행 수치

| 항목 | 결과 |
| --- | ---: |
| 명령 표본 수 | 551 |
| 첫 명령 | 2026-07-24 16:08:42 KST |
| 마지막 명령 | 2026-07-24 16:11:22 KST |
| 평균 보고 추론 FPS | 7.924 |
| 마지막 보고 추론 FPS | 8.0 |
| 사람 최대 동시 탐지 수 | 4 |
| 사람 탐지 표본 수 | 424 |

관찰된 상태와 방향은 다음과 같다.

```text
상태:
  NO_TARGET_HOLD  71
  RETURN_HOME     56
  TRACKING       424

방향:
  DOWN           103
  HOLD            74
  HOME            56
  LEFT            11
  LEFT_DOWN      279
  RIGHT_DOWN      28
```

검증 종료 후 다음 서비스가 모두 `active`인 것을 확인했다.

```text
wj-media-source
wj-mediamtx-local
wj-edge-ai-mvp
```

## 5. 결과 판정

### Jetson 검증 완료

- 로컬 RTSP AI 경로 최초 연결
- 실제 사람 탐지와 다중 객체 관찰
- ByteTrack 기반 추적 ID 생성
- `TRACKING → HOLD → HOME` 상태 전이
- RTSP 강제 중단 감지
- 지수 백오프와 스트림 복구 후 자동 재연결
- 검증 종료 후 기존 서비스 복구

### 부분 검증

- 자동 구도 명령과 박스는 JSONL 수치로 검증했지만 최종 `annotated.mp4`
  육안 검토가 남아 있다.
- 격리된 시험판은 통과했지만 운영 YOLO 경로에는 아직 묶음 배포하지 않았다.

### 미검증

- 실제 고양이 탐지
- 실제 강아지 탐지
- SG90 두 축 실제 구동
- YOLO와 YAMNet을 모두 RTSP로 실행하는 1시간 통합 시험
- 1080p 성능

고양이·강아지는 현장에 대상이 없어 `NOT TESTED`로 기록한다. 이후 사용
허가를 받은 테스트 영상으로 파일 입력 회귀 시험을 하고, 가능할 때 실제
환경 시험을 별도로 진행한다.

## 6. 확인된 한계와 보완 사항

- 평균 추론 속도는 약 7.9 FPS였다. 실시간 입력은 30 FPS이므로 최신 프레임만
  유지하는 방식이 지연 누적 방지에 필수다.
- 시험판의 `Source` 안내 문구는 비동기 캡처가 첫 프레임을 열기 전에
  기본값 640×480을 표시했다. 같은 시험의 `ffprobe`에서는 실제 RTSP가
  H.264 1280×720임을 확인했다. 이후 운영 후보 코드에서는 첫 프레임을 받은
  뒤 실제 프레임 크기를 기록하도록 보완했으며 Jetson 운영 스모크 확인이 남아 있다.
- 이번 시험은 YOLO 단독 기능 시험이다. AI-06의 공식 완료 조건인 YOLO·YAMNet
  동시 1시간 시험을 대체하지 않는다.

## 7. Jira 상태와 완료 조건

현재 권장 상태는 **In Review**다.

Task 1을 `Done`으로 전환하려면 다음 절차를 마친다.

1. `annotated.mp4`에서 사람 라벨, 박스, 대상 선택과 재연결 후 영상 갱신을
   육안 확인한다.
2. 현재 YOLO 디렉터리를 파일별 덮어쓰기가 아닌 하나의 버전 묶음으로
   운영 후보 경로에 배포한다.
3. Jetson YOLO 가상환경에서 전체 관련 단위 테스트를 실행한다.
4. 운영 서비스가 새 묶음을 사용하도록 전환하고 짧은 RTSP 스모크 테스트를 한다.
5. 롤백 경로와 이전 운영 묶음을 유지한다.

고양이·강아지 실물 시험은 별도 테스트 데이터 작업으로 분리하며, 현재
Task 1의 사람·RTSP 복구 검증 결과를 실패 처리하는 근거로 사용하지 않는다.

## 8. Jira 댓글용 요약

```text
[Task 1 YOLO RTSP Jetson 검증]
- 격리 시험판에서 rtsp://127.0.0.1:8554/homecam/ai 입력 확인
- 사람 탐지 PASS: 424표본, 최대 4명, ByteTrack ID 생성 확인
- TRACKING → HOLD → HOME 상태 전이 PASS
- MediaMTX 강제 중단 후 1/2/4/8/10초 백오프 및 자동 재연결 PASS
- JSONL 551줄 중 오류 0줄, 평균 추론 7.924 FPS
- 고양이·강아지는 현장에 없어 NOT TESTED로 분리
- 기존 media source/MediaMTX/AI 서비스 복구 확인
- 증거: /home/ssafy/ai_validation/yolo_rtsp_20260724_160831
- 남은 일: annotated.mp4 육안 확인, 운영 코드 묶음 배포·스모크 테스트
- 권장 Jira 상태: In Review
```
