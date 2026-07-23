# William James IoT Device Agent

This service is the missing edge half of the backend live-stream contract. It
connects to Mosquitto with the provisioned operating credential, reports device
presence, and turns dynamic stream commands into FFmpeg publishers.

## Runtime flow

```text
Flutter POST stream session
  -> Spring publishes START_STREAM over MQTT
  -> agent starts FFmpeg at .../live/{streamId}
  -> agent publishes STREAM_READY
  -> Spring returns the protected HLS URL
  -> Flutter plays HLS and sends viewer heartbeats
  -> STOP_STREAM or hardExpiresAt terminates FFmpeg
```

The agent itself remains focused on MQTT control and on-demand live relay.
`wj-edge-ai-mvp.service` runs YOLO, YAMNet, and the clip uploader beside it,
using loopback media and local event files instead of opening a second MQTT
connection with the same device identity. Current deployment and validation
details are documented in `INTEGRATION_STATUS.md` and
`JETSON_HANDOFF_2026-07-23.md`.

## Install on Jetson (current production server)

The production RTSP port is intentionally bound to server loopback. The Jetson
therefore uses an authenticated SSH local-forward, just like
`backend/demo/start-webcam-live.ps1`. One always-on FFmpeg process opens the
physical webcam and microphone and fans an encoded stream to three loopback UDP
ports. YOLO, YAMNet, and the on-demand live relay each consume a separate local
port, so they never compete for the hardware. Only the live relay crosses the
SSH tunnel, and it exists only between `START_STREAM` and `STOP_STREAM`.

On the Jetson, from the repository checkout:

```bash
cd ai/device_agent
chmod +x install-jetson.sh media-source.sh media-tunnel.sh check-jetson.sh
sudo ./install-jetson.sh
sudoedit /etc/william-james/device-agent.env
```

Use `device-agent.jetson.env.example` as the reference. Set the device ID and
operating bearer token returned by backend provisioning, and install secrets:

```bash
sudo install -m 0644 mqtt-ca.crt /etc/william-james/certs/mqtt-ca.crt
sudo install -m 0600 -o williamjames -g williamjames I15E201T.pem \
  /etc/william-james/ssh/media-tunnel.key
ssh-keyscan -H i15e201.p.ssafy.io | \
  sudo tee /etc/william-james/ssh/known_hosts >/dev/null
sudo chown williamjames:williamjames /etc/william-james/ssh/known_hosts
sudo chmod 600 /etc/william-james/ssh/known_hosts
```

For a brand-new camera, the backend credential flow is:

1. From the server loopback, call `POST /internal/admin/devices` with the
   `X-Provisioning-Key` header. This returns a one-use `BOOTSTRAP` token.
2. Exchange it at `POST /api/iot/enrollment` using
   `Authorization: Bearer <bootstrap token>`. Put the returned `deviceId` and
   `OPERATING` `bearerToken` in the Jetson environment file.
3. With that operating token, call `POST /api/iot/registration-codes`, then
   claim the returned code while signed in to the app as the owner/admin.

Do not put either bearer token in Git or command output captured by CI. The
provisioning endpoint is intentionally loopback-only and is not exposed by
Nginx.

Verify the SSH host-key fingerprint through a trusted channel before accepting
the `ssh-keyscan` result. Then test the tunnel, camera, and broker and start the
services:

```bash
sudo systemctl start wj-media-source wj-media-tunnel
sudo -u williamjames /opt/william-james/device-agent/check-jetson.sh
sudo systemctl start wj-device-agent
sudo systemctl status wj-media-source wj-media-tunnel wj-device-agent --no-pager
```

The camera must be provisioned, claimed by the owner/admin account, and ONLINE.
Opening that camera's Live View in Flutter creates the stream; leaving the view
closes it. A missing client close is covered by the 45-second viewer TTL, the
backend idle stop, and the Jetson hard lease.

Until a physical registration button is wired, run this command on the Jetson
to enter the same two-minute registration mode and print the one-time code:

```bash
sudo -u williamjames \
  /opt/william-james/device-agent/registration-button.sh
```

Enter the displayed `XXXX-XXXX` value in App > Settings > Connect new device.
The command requires the one-time factory provisioning/enrollment flow to have
already stored an OPERATING bearer token in `device-agent.env`. A future GPIO
button handler can invoke this same script without changing the backend or app.

Follow a real request with:

```bash
sudo journalctl -u wj-device-agent -f
pgrep -a ffmpeg
```

There is always one FFmpeg process for the loopback-only shared media source.
Opening Live View adds one relay process; leaving the view removes only that
relay after the session's idle timeout. YOLO and YAMNet keep consuming their
local copies throughout.

## Raspberry Pi 설치

운영 Raspberry Pi에서는 하나의 프로세스만 카메라를 계속 점유하고, 기기
에이전트는 시청자가 있을 때만 릴레이를 실행합니다.

```text
/dev/video0
  -> homecam-publisher
  -> Pi 내부 MediaMTX rtsp://127.0.0.1:8554/homecam
  -> 기기 에이전트 (시청자가 있을 때만 실행)
  -> rtsps://i15e201.p.ssafy.io:8322/live/{streamId}
```

이 구조는 `homecam-publisher`와 기기 에이전트가 같은 V4L2 장치를 동시에 여는
문제를 방지합니다. 가능하면 `homecam-publisher`에서
`/dev/v4l/by-id/...-video-index0`처럼 고정된 카메라 경로를 사용하세요.
`/dev/video0`은 재부팅하거나 USB를 다시 연결하면 바뀔 수 있습니다.

```bash
cd ai/device_agent
chmod +x scripts/*.sh homecam-publisher.sh
sudo ./scripts/prepare-pi.sh /path/to/mqtt-ca.crt
sudo ./scripts/configure-pi-rtsps.sh
```

준비 스크립트는 MediaMTX 설치 및 체크섬 검증, Python 실행 환경 생성, systemd
서비스 3개 설치, Pi 내부 MediaMTX 시작까지 처리합니다. 기기 에이전트는
enrollment 전까지 중지 상태로 둡니다. 이 단계에는 bootstrap 자격증명이
필요하지 않으므로 짧게 유지되는 토큰을 만들기 전에 실행하세요.

EC2에서는 `scripts/create-device-on-server.sh`를 사용해 bootstrap 토큰을
화면에 출력하지 않고 권한 600 파일에 바로 저장합니다. 해당 파일만 Pi로
전달한 뒤 enrollment를 실행합니다.

```bash
sudo ./scripts/enroll-pi.sh /home/pi/wj-bootstrap.token
```

USB 카메라를 연결하고 설정한 뒤:

```bash
sudoedit /etc/william-james/homecam-publisher.env
sudo systemctl start homecam-publisher

ffprobe -v error -rtsp_transport tcp \
  -show_entries stream=codec_type,codec_name,width,height \
  -of default=noprint_wrappers=1 \
  rtsp://127.0.0.1:8554/homecam
```

스트림은 온라인 상태이며 H.264여야 합니다. 원격 TLS listener는 별도로
확인합니다.

```bash
openssl s_client \
  -connect i15e201.p.ssafy.io:8322 \
  -servername i15e201.p.ssafy.io \
  -verify_return_error </dev/null
```

서비스를 활성화하기 전에 짧은 인증 RTSPS 송출 시험을 수행합니다. MediaMTX
계정에는 `live/*` 경로의 송출 전용 권한이 있어야 합니다. TLS만으로는 기기를
인증하지 않습니다. 직접 RTSPS 송출이 성공하면 SSH 터널은 필요하지 않습니다.

```bash
sudo systemctl disable --now wj-media-tunnel
sudo systemctl restart wj-device-agent
```

EC2와 Pi 전체 절차, 보안 규칙, 자격증명 갱신, 카메라 진단과 정상 로그는
`RASPBERRY_PI_RUNBOOK.md`에서 확인할 수 있습니다.

## Jetson adapter

The default FFmpeg input uses Raspberry Pi V4L2. A Jetson can replace the input
and encoder without changing MQTT logic by setting JSON argument arrays:

```text
FFMPEG_INPUT_ARGS='["-f","v4l2","-framerate","30","-video_size","1280x720","-i","/dev/video0"]'
FFMPEG_VIDEO_ARGS='["-c:v","h264_v4l2m2m","-b:v","2500k","-g","60"]'
```

Use arguments verified on the target JetPack release; NVIDIA CSI/DeepStream
pipelines can instead expose a local RTSP source and configure FFmpeg to copy it.

The checked-in Jetson example deliberately starts with `libx264`, which works
without a JetPack-specific FFmpeg build. Hardware encoder names vary by JetPack
and FFmpeg package, so only replace `FFMPEG_VIDEO_ARGS` after checking
`ffmpeg -encoders` and making a short capture. For a USB webcam, confirm its
actual modes with `v4l2-ctl --device=/dev/video0 --list-formats-ext`.

## Operations

```bash
sudo systemctl status wj-device-agent
sudo journalctl -u wj-device-agent -f
sudo systemctl restart wj-device-agent
```

On Jetson, inspect the tunnel too:

```bash
sudo systemctl status wj-media-tunnel
sudo journalctl -u wj-media-tunnel -f
```

The service deliberately suppresses FFmpeg stderr because publish URLs can
contain credentials. Add a redacting log collector before enabling FFmpeg debug
logs. If the relay exits, the agent reports `STREAM_RELAY_EXITED`; this covers
input-device, local RTSP, codec, TLS, authentication, and remote MediaMTX
failures, not only encoder availability. Reproduce the generated FFmpeg command
manually with a redacted URL to see the underlying stderr.
