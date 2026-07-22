# Jetson 홈캠 통합 작업 인수인계 (2026-07-22~23)

## 1. 오늘 도달한 상태

Jetson Orin Nano에 연결한 Logitech Brio 100의 영상과 음성을 다음 구조로 통합했다.

```text
Brio 100 (/dev/video0 + ALSA B100)
  -> wj-media-source (항상 실행, 장치를 한 번만 점유)
     -> UDP 23000 -> YOLO/ByteTrack (항상 실행)
     -> UDP 23001 -> YAMNet (항상 실행)
     -> UDP 23002 -> 라이브 FFmpeg (앱 시청 중에만 실행)
                       -> SSH 로컬 포워드
                       -> 서버 MediaMTX RTSP
                       -> 보호된 HLS
                       -> Flutter 플레이어
```

검증된 항목:

- 물리 카메라와 마이크를 공유 소스 FFmpeg 하나로 동시에 캡처한다.
- 기기 등록 코드를 가상 버튼 스크립트로 발급하고 앱 계정에서 기기를 등록했다.
- MQTT TLS 연결, 기기 ONLINE 표시, 앱 Live View의 영상과 소리를 확인했다.
- 앱이 Live View를 열 때만 별도의 RTSP 릴레이 FFmpeg가 실행된다.
- YOLO/ByteTrack은 Live View와 무관하게 계속 실행된다.
- 사람 감지 시 `RIGHT_DOWN`, `DOWN`, `HOLD`, `HOME` 등의 모의 모터 명령이 로그에 출력됐다.
- YAMNet은 Brio 100 마이크 입력을 받아 웃음을 감지했다.
- 웃음 이벤트에 대해 앞 5초 + 뒤 5초의 오디오와 비디오 파일 생성까지 확인했다.

아직 완료 확인이 안 된 항목:

- 웃음 클립의 서버 업로드 완료. 마지막 확인 시 `.trigger.json`, `.audio.wav`, `.video.mp4`, `.tmp.mp4`까지 생성됐지만 `Uploaded laughter clip` 로그와 `.uploaded.json` 표식은 없었다. 즉 감지/버퍼/파일 생성은 성공했고, mux 또는 업로드 단계는 다음 작업에서 이어서 확인해야 한다.
- 실제 팬/틸트 모터 제어. 현재는 방향 계산과 로그 출력만 한다.

## 2. 배포된 구성

### Jetson

- 사용자: `ssafy`
- 장치 에이전트: `/opt/william-james/device-agent`
- 장치 설정: `/etc/william-james/device-agent.env`
- AI 코드: `/home/ssafy/ai/yolo`, `/home/ssafy/ai/yamnet`
- 이벤트/로그: `/home/ssafy/ai_events`
- SSH 터널 키: `/etc/william-james/ssh/media-tunnel.key`
- 카메라: `/dev/video0`
- 마이크: `plughw:CARD=B100,DEV=0`

서비스:

| 서비스 | 실행 조건 | 역할 |
|---|---|---|
| `wj-media-source` | 항상 | Brio 100을 한 번만 열고 로컬 UDP 세 경로로 분배 |
| `wj-edge-ai-mvp` | 항상 | YOLO, YAMNet, 클립 업로더 실행 |
| `wj-media-tunnel` | 항상 | Jetson `127.0.0.1:18554`를 서버 MediaMTX `127.0.0.1:8554`로 포워드 |
| `wj-device-agent` | 항상 | MQTT 명령 수신, 상태 보고, 시청 세션 동안만 라이브 릴레이 실행 |

### 서버

- 운영 주소: `https://i15e201.p.ssafy.io`
- 백엔드는 커밋 `838f6bf`로 빌드한 JAR까지 배포했다.
- 배포 전 JAR 백업: `/home/ubuntu/william-james/app/server.jar.before-838f6bf`
- `DEMO_MODE_ENABLED=false`, `DEMO_LIVE_HLS_URL=` 상태로 실제 기기 경로를 사용한다.
- 외부 업로드용 S3 서명 URL 생성을 위해 `S3_PUBLIC_ENDPOINT=https://i15e201.p.ssafy.io`를 설정했다.

토큰, MQTT 비밀번호, PEM 원문은 Git에 넣지 않는다.

## 3. 중요한 런타임 설정

`/etc/william-james/device-agent.env`의 미디어 관련 핵심값은 다음과 같다.

```dotenv
MEDIA_PUBLISH_URL_TEMPLATE=rtsp://127.0.0.1:18554/live/{stream_id}
FFMPEG_PATH=/usr/bin/ffmpeg
AUDIO_DEVICE=plughw:CARD=B100,DEV=0

YOLO_UDP_PORT=23000
YAMNET_UDP_PORT=23001
LIVE_UDP_PORT=23002
YOLO_SOURCE_URL=udp://127.0.0.1:23000?fifo_size=1000000&overrun_nonfatal=1
YAMNET_SOURCE_URL=udp://127.0.0.1:23001?fifo_size=1000000&overrun_nonfatal=1

FFMPEG_INPUT_ARGS='["-fflags","nobuffer","-flags","low_delay","-i","udp://127.0.0.1:23002?fifo_size=1000000&overrun_nonfatal=1"]'
FFMPEG_VIDEO_ARGS='["-c:v","copy"]'
FFMPEG_AUDIO_INPUT_ARGS='[]'
FFMPEG_AUDIO_ARGS='["-c:a","aac","-b:a","128k","-ar","48000","-ac","1"]'
FFMPEG_AUDIO_FROM_PRIMARY_INPUT=true
```

Brio 100 실측 결과에 맞춘 YAMNet 기본값:

```text
threshold=0.05
consecutive=2
gain=1.5
cooldown=12초
clip=앞 5초 + 뒤 5초
```

진단 중 웃음 점수 최고값은 `0.141`이었다. 초기값 `0.20`에서는 감지되지 않았고, `0.05`와 2회 연속 조건에서 실제 이벤트가 생성됐다. 장소와 사용자에 따른 오탐/미탐 측정은 추가로 필요하다.

## 4. 기존 Jetson에서 실행하는 방법

재부팅 후 네 서비스가 자동 시작되도록 enable 상태여야 한다.

```bash
sudo systemctl enable --now \
  wj-media-source \
  wj-edge-ai-mvp \
  wj-media-tunnel \
  wj-device-agent
```

상태 확인:

```bash
sudo systemctl status \
  wj-media-source \
  wj-edge-ai-mvp \
  wj-media-tunnel \
  wj-device-agent \
  --no-pager -l
```

정상적인 상시 FFmpeg:

```bash
pgrep -af ffmpeg
```

- 항상 존재: 카메라/마이크 공유 소스 FFmpeg
- 항상 존재: YAMNet용 오디오 디코더 FFmpeg
- 앱 Live View 중에만 추가: UDP 23002에서 RTSP `/live/{streamId}`로 보내는 FFmpeg

## 5. 기기 등록부터 라이브 확인까지

실제 GPIO 버튼이 없으므로 현재는 아래 명령을 버튼 누름으로 간주한다.

```bash
sudo -u williamjames \
  /opt/william-james/device-agent/registration-button.sh
```

1. 터미널에 출력된 `XXXX-XXXX` 코드를 앱의 기기 등록 화면에 입력한다.
2. 최대 수 초 동안 기기 등록과 MQTT 상태 반영을 기다린다.
3. 앱에서 기기가 ONLINE인지 확인한다.
4. Live View를 연다.
5. Jetson에서 `pgrep -af ffmpeg`를 실행해 RTSP 릴레이 프로세스가 추가됐는지 확인한다.
6. Live View를 완전히 닫고 idle timeout 후 해당 릴레이만 종료되는지 확인한다.

등록 코드는 2분짜리 일회용이다. 등록 시도 제한에 걸렸다면 반복 호출하지 말고 제한 시간이 지난 뒤 다시 시도한다.

## 6. YOLO 확인 방법

최신 로그 디렉터리를 찾는다.

```bash
ai_run_dir=$(find ~/ai_events/logs -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
tail -f "$ai_run_dir/yolo.log"
```

얼굴만 가까이 비추는 것이 아니라 상반신 또는 전신이 보이게 1~2m 떨어져 테스트한다. 이 모델은 얼굴 인식이 아니라 COCO `person` 탐지다.

주요 로그 의미:

- `targets=1/1`: 사람 한 명 감지 및 추적
- `RIGHT`, `LEFT`, `UP`, `DOWN`, 조합 명령: 화면 중앙으로 옮겨야 할 방향
- `HOLD`: 잠시 대상을 놓쳤으나 현재 위치 유지
- `HOME`: 장시간 대상이 없어 기본 위치 복귀 요청

현재 모터 출력은 비활성화되어 있으며 `autoframe_commands.jsonl`과 로그만 생성한다.

## 7. YAMNet과 웃음 클립 확인 방법

서비스가 시작된 뒤 YAMNet 모델과 UDP 입력 준비에 약 15~20초가 걸릴 수 있다.

```bash
ai_run_dir=$(find ~/ai_events/logs -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
grep -E 'Local laughter event|Saved laughter' "$ai_run_dir/yamnet.log" | tail -n 20
tail -n 50 "$ai_run_dir/uploader.log"
find ~/ai_events -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM:%TS %f\n' | sort | tail -n 30
```

한 이벤트가 정상 처리되면 같은 UUID로 다음 파일이 생성된다.

```text
<eventId>.trigger.json
<eventId>.audio.wav
<eventId>.video.mp4
<eventId>.mp4
<eventId>.uploaded.json
```

`uploaded.json`과 `Uploaded laughter clip`이 있어야 서버 업로드 완료다. `.tmp.mp4`만 남아 있으면 mux가 진행 중이거나 실패한 상태다.

## 8. 다음 작업: 웃음 클립 업로드 완료시키기

가장 먼저 마지막 이벤트의 업로더 상태를 확인한다.

```bash
ai_run_dir=$(find ~/ai_events/logs -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
tail -n 100 "$ai_run_dir/uploader.log"
pgrep -af laughter_clip_uploader
find ~/ai_events -maxdepth 1 -type f -ls | tail -n 30
```

`.tmp.mp4`가 오래 유지되면 다음을 확인한다.

```bash
ffprobe -v error -show_streams ~/ai_events/<eventId>.video.mp4
ffprobe -v error -show_streams ~/ai_events/<eventId>.audio.wav
ffprobe -v error -show_streams ~/ai_events/<eventId>.tmp.mp4
```

확인 순서:

1. mux FFmpeg가 끝나는지, CPU를 계속 사용하는지 확인한다.
2. 최종 `<eventId>.mp4`가 생성되는지 확인한다.
3. `/api/iot/videos/upload-url` 호출의 HTTP 상태를 업로더 로그에서 확인한다.
4. 반환된 공개 presigned URL이 Jetson에서 접근 가능한지 확인한다.
5. PUT 완료 후 `/api/iot/videos/complete`가 성공하는지 확인한다.
6. `.uploaded.json` 생성과 앱의 최근 저장 영상 반영을 확인한다.
7. 실패 재시도 시 같은 `eventId`의 idempotency가 유지되는지 확인한다.

추가 잔여 작업:

- 업로더 로그에 mux/API/PUT 단계별 시작과 종료를 명시해 멈춘 위치를 바로 알 수 있게 한다.
- 오래 남은 `.tmp.mp4` 처리와 디스크 보존/삭제 정책을 추가한다.
- YAMNet 임계값을 여러 사람, 거리, TV 소음 환경에서 재측정한다.
- YOLO 방향 출력을 실제 팬/틸트 각도 및 PWM 제어와 연결한다.
- `install-jetson.sh`가 AI 코드와 `wj-edge-ai-mvp.service`까지 한 번에 설치하도록 통합한다.
- 재부팅, 네트워크 단절/복구, 앱 강제 종료 시나리오를 자동 테스트한다.

## 9. 오늘 겪은 문제와 해결 내용

### Jetson 파일 전송과 접속

- USB 연결 시 Windows에 보인 `L4T-README` 드라이브는 일반 파일 배포 경로가 아니었다.
- USB 네트워크 주소 `192.168.55.1`로 SSH/SCP를 사용했다.
- Windows PowerShell 환경변수는 `:USERPROFILE`이 아니라 `$env:USERPROFILE` 형식이다.
- Wi-Fi의 `Not authorized` 오류는 Jetson에서 권한 있는 사용자 또는 `sudo nmcli`로 처리했다.
- Jetson 화면에서 실행한 `apt update` 취소는 `Ctrl+C`이며, 이후 작업은 Windows SSH 터미널에서 진행해도 동일하다.

### 기기 등록

- 초기 bootstrap API는 MyBatis가 `UUID`를 리플렉션으로 생성하려다 `InaccessibleObjectException`이 발생했다. UUID 결과 매핑을 수정한 백엔드로 재배포한 뒤 해결됐다.
- `401 DEVICE_AUTHENTICATION_FAILED`는 현재 운영 토큰과 기기 상태가 일치하지 않을 때 발생했다. 올바른 OPERATING 토큰을 환경 파일에 반영하고 에이전트를 재시작해야 한다.
- 등록 코드를 짧은 시간에 반복 발급하면 rate limit에 걸린다.

### 라이브 스트리밍

- `mjpeg ... unable to decode APP fields`는 Brio MJPEG 메타데이터 경고였고 프레임 처리는 계속됐다.
- 앱의 무한 로딩/`PlatformException(Source error)` 때 `pgrep -af ffmpeg`에 라이브 릴레이가 없었다. MQTT START/READY 흐름과 stale RUNNING 세션을 수정해 새 시청 요청마다 fresh handshake하도록 했다.
- MPEG-TS의 AAC를 RTSP로 그대로 copy하면 `AAC with no global headers ... Server returned 400`으로 실패했다. 비디오는 copy하되 오디오는 AAC로 재인코딩하도록 변경했다.
- UDP에 늦게 붙은 소비자에서 `non-existing PPS`가 반복됐다. 공유 인코더에 `repeat-headers=1`을 적용했다. 시작 직후 일부 경고는 남을 수 있으나 SPS/PPS를 받은 뒤 정상 프레임과 스트림을 확인했다.
- `diagnose_stream.py`로 원격 MediaMTX에 H264/AAC를 publish하고 다시 읽는 `RESULT=RTSP_PUBLISH_AND_READ_OK`를 확인했다.

### YOLO/YAMNet

- YOLO가 `targets=0/0`만 출력한 초기 테스트는 얼굴만 가까이 비춘 영향이 있었다. 상반신이 보이자 `targets=1/1`, `RIGHT_DOWN`, `DOWN`이 확인됐다.
- YAMNet의 진행 상태는 `\r`로 같은 줄을 갱신해 `sed | tee` 로그에서 바로 보이지 않았다. 초기 로그가 비어 보여도 프로세스와 모델 준비 상태를 함께 확인해야 한다.
- YAMNet 초기 임계값 `0.20`은 Brio 100 실측 최고 웃음 점수 `0.141`보다 높아 감지되지 않았다. `0.05`, 2회 연속으로 조정한 뒤 이벤트와 5초 pre/post 파일이 생성됐다.
- 모델/UDP 소비자가 서비스 재시작 후 준비되는 데 약 15~20초가 걸렸다. 재시작 직후 바로 웃으면 테스트를 놓칠 수 있다.

## 10. 코드 검증 기록

커밋 `838f6bf` 배포 전에 다음을 통과했다.

- device-agent 테스트 6개
- AI 하드웨어 비의존 테스트 11개
- 백엔드 전체 Gradle 테스트
- Jetson 실기 RTSP publish/read 진단
- 앱 Live View 영상 및 음성 재생
- YOLO 실기 사람 감지와 방향 명령
- YAMNet 실기 웃음 이벤트 및 10초 원본 파일 생성

서버 업로드 완료 및 앱 최근 영상 반영은 다음 세션에서 마무리한다.
