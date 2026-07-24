# 웃음 감지 전후 60초 이벤트 녹화 런북

이 문서는 Jetson에서 다음 경로를 실기로 확인하는 절차다.

```text
웹캠 영상·마이크
→ 로컬 RTSP main/ai
→ 1분 MPEG-TS 순환 녹화
→ YAMNet 웃음 감지
→ 최초 웃음 60초 전부터 마지막 웃음 60초 후까지 MP4 추출
```

2026-07-24 Jetson Orin Nano에서 웃음 감지, 로컬 이벤트 MP4 생성,
H.264/AAC 스트림 포함과 노트북 다운로드까지 확인했다.

## 1. 성공 기준

다음 조건을 모두 만족하면 성공이다.

- `wj-media-source`, `wj-mediamtx-local`, `wj-local-recording`,
  `wj-edge-ai-recording`이 `active (running)`이다.
- `homecam/main`과 `homecam/ai`에 H.264 영상과 AAC 음성이 모두 있다.
- YAMNet 로그에 `Audio stream connected`와 `Local laughter event`가 나온다.
- `~/ai_events/<eventId>.mp4`가 생성된다.
- 이벤트 MP4에 H.264 영상과 AAC 음성이 있고 길이가 약 120초 이상이다.
- 30초 안에 이어진 웃음은 첫 이벤트를 기준으로 같은 클립에 병합된다.

서버 업로드의 `HTTP 409`는 별도 문제다. MP4가 이미 생성돼 있다면 이
런북의 범위인 로컬 이벤트 녹화는 성공으로 판정한다.

## 2. 고정 경로와 배포 일관성

systemd 서비스는 다음 경로를 사용한다.

```text
/home/ssafy/ai/yolo
/home/ssafy/ai/yamnet
/home/ssafy/ai_events
/var/lib/william-james/recordings
/etc/william-james/device-agent.env
```

`/home/ssafy/ai_rtsp_trial` 같은 시험 디렉터리에서 서비스 파일만 설치하고
실제 Python·셸 파일을 `/home/ssafy/ai`에 반영하지 않으면 버전이 섞인다.
릴리스할 때는 `yolo`와 `yamnet`을 한 묶음으로 배포한다. 일부 파일만
복사하지 않는다.

배포 후 다음 사전 검사를 실행한다.

```bash
test -x /home/ssafy/ai/yolo/run_edge_ai_recording.sh
test -f /home/ssafy/ai/yolo/segment_clip_uploader.py
test -f /home/ssafy/ai/yamnet/yamnet_laughter_detect_jetson.py
test -f /home/ssafy/ai/yamnet/ffmpeg_audio_stream.py
test -f /home/ssafy/ai/yamnet/mqtt_event_publisher.py

/home/ssafy/venvs/yamnet/bin/python \
  /home/ssafy/ai/yamnet/yamnet_laughter_detect_jetson.py \
  --help |
grep -- '--trigger-only'

systemctl cat wj-edge-ai-recording |
grep -E 'WorkingDirectory=|ExecStart='
```

`--trigger-only`가 표시되지 않거나 `ModuleNotFoundError`가 발생하면
YAMNet 패키지가 구버전 또는 부분 배포 상태다. 현재 릴리스의 `yamnet`
디렉터리 전체를 다시 배포한다.

## 3. 마이크 장치 확인

ALSA 카드 번호는 USB 재연결로 달라질 수 있으므로 숫자 대신 카드 ID를
사용한다. `B100`으로 가정하지 말고 매번 실제 값을 확인한다.

```bash
arecord -l
cat /proc/asound/cards
lsusb
```

예를 들어 다음과 같이 나오면 카드 ID는 `Camera`다.

```text
card 0: Camera [Web Camera], device 0: USB Audio
```

설정 파일을 수정한다. 모든 설정 파일 조회에는 `sudo`를 사용한다.

```bash
if sudo grep -q '^AUDIO_DEVICE=' \
  /etc/william-james/device-agent.env; then
  sudo sed -i \
    's|^AUDIO_DEVICE=.*|AUDIO_DEVICE=plughw:CARD=Camera,DEV=0|' \
    /etc/william-james/device-agent.env
else
  echo 'AUDIO_DEVICE=plughw:CARD=Camera,DEV=0' |
    sudo tee -a /etc/william-james/device-agent.env
fi

sudo grep -n '^AUDIO_DEVICE=' \
  /etc/william-james/device-agent.env
```

`Camera` 부분은 `arecord -l`에 나온 실제 카드 ID로 바꾼다.

서비스 계정으로 5초 녹음한다.

```bash
mic_test="/tmp/wj-mic-test-$(date +%s).wav"

sudo -u williamjames arecord \
  -D plughw:CARD=Camera,DEV=0 \
  -f S16_LE -r 48000 -c 1 -d 5 \
  "$mic_test"

ffprobe -v error \
  -show_entries stream=codec_type,codec_name,sample_rate,channels,duration \
  -of default=noprint_wrappers=1 \
  "$mic_test"
```

`pcm_s16le`, `48000`, mono, `duration=5`가 나오면 정상이다.
`/nonexistent/.config/pulse` 경고는 명시한 ALSA 녹음이 성공했다면 시험을
막지 않는다.

## 4. 로컬 파일 보존 설정

기본 동작은 업로드 성공 후 이벤트 MP4를 삭제한다. 실기 시험에서는
로컬 파일을 남긴다.

```bash
if sudo grep -q '^DELETE_EVENT_AFTER_UPLOAD=' \
  /etc/william-james/device-agent.env; then
  sudo sed -i \
    's/^DELETE_EVENT_AFTER_UPLOAD=.*/DELETE_EVENT_AFTER_UPLOAD=false/' \
    /etc/william-james/device-agent.env
else
  echo 'DELETE_EVENT_AFTER_UPLOAD=false' |
    sudo tee -a /etc/william-james/device-agent.env
fi

sudo grep -n '^DELETE_EVENT_AFTER_UPLOAD=' \
  /etc/william-james/device-agent.env
```

이 설정은 업로드를 끄지 않는다. 업로드 후에도 MP4를 남기는 설정이다.

## 5. 로컬 RTSP 시작

기존 5초 MVP와 디스크 기반 AI를 먼저 멈춘다.

```bash
sudo systemctl stop \
  wj-edge-ai-mvp \
  wj-edge-ai-recording \
  wj-local-recording

sudo systemctl restart wj-media-source
sleep 5
sudo systemctl restart wj-mediamtx-local
sleep 10

sudo systemctl status \
  wj-media-source wj-mediamtx-local \
  --no-pager
```

두 RTSP 경로의 영상과 음성을 확인한다.

```bash
for path in main ai; do
  echo "=== $path ==="
  ffprobe -v error -rtsp_transport tcp \
    -show_entries stream=index,codec_type,codec_name \
    -of compact=p=0:nk=1 \
    "rtsp://127.0.0.1:8554/homecam/$path"
done
```

정상 출력은 두 경로 모두 다음과 같다.

```text
0|h264|video
1|aac|audio
```

## 6. 순환 녹화와 사전 버퍼 확보

이벤트 전 60초를 얻으려면 웃기 전에 완성된 세그먼트가 있어야 한다.

```bash
sudo systemctl restart wj-local-recording
sleep 70

sudo systemctl status wj-local-recording --no-pager

sudo -u williamjames find /var/lib/william-james/recordings \
  -maxdepth 1 -type f -name 'homecam-*.ts' \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %f\n' |
sort |
tail
```

일반 `ssafy` 계정으로 녹화 디렉터리를 읽으면 `Permission denied`가 날 수
있다. 파일 확인에는 `sudo -u williamjames`를 사용한다.

## 7. 과거 트리거 격리

과거 `*.trigger.json`이 남아 있으면 현재 녹화가 덮지 못하는 시각을 계속
요청하거나 서버에 이미 처리한 이벤트를 다시 보낼 수 있다. 시험 전에는
삭제하지 말고 격리한다.

```bash
legacy="$HOME/ai_events/legacy-triggers-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$legacy"

find "$HOME/ai_events" -maxdepth 1 \
  -type f -name '*.trigger.json' \
  -exec mv -t "$legacy" -- {} +

echo "과거 트리거 격리 위치: $legacy"
```

새 시험에서 만든 파일만 찾을 수 있도록 기준 파일도 만든다.

```bash
touch "$HOME/ai_events/.laughter-test-start"
```

## 8. 디스크 기반 AI 시작

```bash
sudo systemctl restart wj-edge-ai-recording
sleep 30

sudo systemctl status wj-edge-ai-recording --no-pager

pgrep -af \
  'yamnet_laughter_detect_jetson|segment_clip_uploader|yolov8_autoframe'
```

세 프로세스가 각각 보여야 한다. YAMNet 로그도 확인한다.

```bash
sudo journalctl -u wj-edge-ai-recording \
  --since '1 minute ago' \
  --no-pager -o cat |
grep '\[YAMNET\]'
```

다음 메시지가 나오기 전에는 웃음 시험을 시작하지 않는다.

```text
Audio stream connected: rtsp://127.0.0.1:8554/homecam/ai
```

현재 코드는 FFmpeg가 지원하는 RTSP 타임아웃 옵션을 자동으로 탐색한다.
`rw_timeout`, `stimeout`, `timeout` 중 지원되는 값을 사용하며 아무것도
지원하지 않으면 타임아웃 옵션 없이 스트림을 연다. 구버전 코드에서
`Option rw_timeout not found`가 나오면 `yamnet` 전체를 최신 릴리스로
다시 배포한다.

## 9. 실제 웃음 시험

로그를 연다.

```bash
sudo journalctl -fu wj-edge-ai-recording -o cat |
grep --line-buffered -E \
  'Local laughter event|Audio stream|Rolling clip|Uploaded rolling|failed|pending'
```

마이크 가까이에서 자연스럽게 웃는다. 기본 디스크 경로 설정은 다음과
같다.

```text
threshold=0.05
consecutive=2
cooldown=12초
```

감지 성공 시 다음 로그가 나온다.

```text
Local laughter event: <eventId>
```

30초 안에 추가로 감지된 웃음은 같은 클립 후보로 병합된다. 마지막 웃음
60초 후까지 기다리고, 그 구간을 가진 현재 1분 세그먼트가 완성돼야 하므로
MP4 생성에는 마지막 감지 후 약 1~2분이 걸릴 수 있다.

## 10. MP4 생성과 품질 검증

이번 시험에서 생성된 MP4를 찾는다.

```bash
find "$HOME/ai_events" -maxdepth 1 \
  -type f -name '*.mp4' \
  -newer "$HOME/ai_events/.laughter-test-start" \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' |
sort
```

최신 MP4의 영상·음성·길이를 검사한다.

```bash
event_mp4="$(
  find "$HOME/ai_events" -maxdepth 1 \
    -type f -name '*.mp4' \
    -newer "$HOME/ai_events/.laughter-test-start" \
    -printf '%T@ %p\n' |
  sort -nr |
  sed -n '1s/^[^ ]* //p'
)"

test -n "$event_mp4"
echo "$event_mp4"

ffprobe -v error \
  -show_entries format=filename,duration,size \
  -show_entries stream=index,codec_type,codec_name \
  -of default=noprint_wrappers=1 \
  "$event_mp4"
```

성공 기준은 H.264 영상, AAC 음성, 약 120초 이상의 길이다. 여러 웃음이
병합되면 길이는 120초보다 길 수 있다.

`Rolling clip pending: waiting for recording coverage after the event`는
후행 세그먼트를 기다리는 정상 상태다. `HTTP Error 409`가 나오더라도
MP4가 존재하고 `ffprobe`가 통과하면 로컬 녹화는 성공이다.

## 11. 노트북으로 다운로드

Jetson에서 IP를 확인한다.

```bash
hostname -I
```

Windows 노트북에서 새 PowerShell을 열고 실행한다. `<JETSON_IP>`와
`<eventId>`를 실제 값으로 바꾼다.

```powershell
$jetsonIp = "<JETSON_IP>"
$eventId = "<eventId>"
$destination = "$env:USERPROFILE\Downloads\laughter-events"

New-Item -ItemType Directory -Force -Path $destination

scp "ssafy@${jetsonIp}:/home/ssafy/ai_events/${eventId}.mp4" `
  $destination

Get-ChildItem $destination
explorer.exe $destination
```

## 12. 시험 종료

서버가 `HTTP 409`를 반환하면 업로더가 같은 요청을 반복하므로 시험이
끝난 뒤 디스크 기반 AI를 멈춘다. 순환 녹화는 필요에 따라 유지한다.

```bash
sudo systemctl stop wj-edge-ai-recording
```

기존 5초 MVP로 복귀해야 할 때만 다음을 실행한다.

```bash
sudo systemctl start wj-edge-ai-mvp
```

## 13. 장애별 확인표

| 증상 | 원인 | 조치 |
|---|---|---|
| `status=127`, `run_edge_ai_recording.sh: No such file` | 서비스 경로와 코드 배포 경로 불일치 | `/home/ssafy/ai`에 같은 릴리스의 `yolo`·`yamnet` 전체를 배포 |
| `Cannot get card index for B100` | 실제 ALSA 카드 ID가 다름 | `arecord -l` 확인 후 `AUDIO_DEVICE` 수정 |
| RTSP `main`이 `404` | `wj-media-source`가 마이크·카메라 오류로 종료 | 해당 서비스 로그와 ALSA 설정 확인 |
| `unrecognized arguments: --trigger-only` | YAMNet 진입 파일이 구버전 | `yamnet` 전체를 같은 릴리스로 배포 |
| `ModuleNotFoundError: ffmpeg_audio_stream` | YAMNet 보조 모듈 누락 | `yamnet` 전체를 같은 릴리스로 배포 |
| `Option rw_timeout not found` | Jetson FFmpeg 옵션 차이 | 자동 옵션 탐색이 포함된 최신 `yamnet` 배포 |
| `Trigger scan failed` | 비었거나 손상된 과거 JSON | 해당 트리거를 삭제하지 말고 별도 디렉터리로 격리 |
| `recording gap before ...` | 오래된 트리거 또는 실제 녹화 공백 | 과거 트리거 격리 후 로컬 녹화 상태 확인 |
| `waiting for recording coverage` | 이벤트 후 세그먼트가 아직 열려 있음 | 마지막 웃음 후 최대 약 2분 대기 |
| `HTTP Error 409` 반복 | 서버가 이벤트 업로드 요청을 거절 | 로컬 MP4 검증 후 AI 서비스를 멈추고 업로드 계약 별도 수정 |
| 녹화 디렉터리 `Permission denied` | `ssafy`가 녹화 그룹 파일을 직접 읽음 | `sudo -u williamjames find ...` 사용 |

