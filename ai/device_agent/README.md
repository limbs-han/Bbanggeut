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
  -> Spring returns the protected WebRTC/WHEP URL
  -> Flutter plays WHEP and sends viewer heartbeats
  -> STOP_STREAM or hardExpiresAt terminates FFmpeg
```

Two-way audio reverses that path for audio only:

```text
Flutter POST talkback
  -> Spring publishes START_TALKBACK over MQTT
  -> agent reads .../talkback/{streamId} and plays it to the speaker
  -> STOP_TALKBACK or hardExpiresAt terminates the player
```

The player is a separate process from the live publisher on purpose. Muting the
device uplink instead would mean restarting the publishing FFmpeg, which breaks
the video every time somebody speaks. The echo loop is cut on the app side: the
app mutes its own WHEP playback while transmitting.

`TALKBACK_ENABLED` is off by default. Without it `START_TALKBACK` is rejected
with `SPEAKER_UNAVAILABLE` rather than accepted by a device with no speaker.

### Testing the Jetson speaker output

After wiring the USB audio adapter, PAM8403, and passive speaker, list the ALSA
playback devices and run a three-second tone before enabling talkback. FFmpeg's
`sine` source is one-eighth of full scale by default, so the script compensates
it by 8x and then applies `SPEAKER_TEST_LEVEL`. The default level is `0.25`,
approximately -12 dBFS; `1.0` produces an approximately 0 dBFS full-scale
signal. Keep earphones out of your ears and the PAM8403 knob near minimum for
the first run:

```bash
sudo apt-get install -y alsa-utils
cd /opt/william-james/device-agent
bash ./test-speaker-output.sh --list
bash ./test-speaker-output.sh plughw:CARD=Device,DEV=0 3
```

For ALSA names containing `CARD=...`, the script also unmutes the card's
`Speaker` mixer and raises it to 100%. This prevents a restored USB mixer value
such as 29% from making a 100% generated signal sound quiet.

To adjust the digital test level, set a value between 0 and 1. For example,
`SPEAKER_TEST_LEVEL=0.5 bash ./test-speaker-output.sh` runs at one half of the
full-scale peak.

Replace `Device` with the card identifier reported by `aplay -L`. The script
uses `TALKBACK_OUTPUT_DEVICE` when no device argument is supplied, so the final
configuration can be verified directly:

```bash
set -a
source /etc/william-james/device-agent.env
set +a
bash ./test-speaker-output.sh
```

The tone is duplicated to both stereo channels. A single speaker on
`LOUT+`/`LOUT-` or `ROUT+`/`ROUT-` therefore receives the same test signal.
Start with the PAM8403 hardware knob near minimum. Never connect either output
minus terminal to power or signal ground because the module uses bridge-tied
speaker outputs.

### Standing in for the device with a laptop

The talkback player is the only speaker-dependent part, so a laptop can take the
device role before the hardware arrives. Point `TALKBACK_COMMAND` at `ffplay`,
which writes to the default system audio output on any OS:

```text
TALKBACK_ENABLED=true
TALKBACK_COMMAND='["ffplay","-hide_banner","-loglevel","warning","-nodisp","-autoexit","-rtsp_transport","tcp","{url}"]'
```

This exercises the MQTT commands, the read URL, and the player lifecycle. It does
not exercise ALSA device selection or on-device echo behaviour.

On Windows start the agent through `run-agent.ps1` rather than calling the module
directly:

```powershell
./run-agent.ps1
```

`device-agent.env` is a systemd `EnvironmentFile`, so on Jetson and Pi systemd
loads it into the process environment. Windows has no such step and
`python -m wj_device_agent` would fail on the first missing variable. The wrapper
reads the same file with the same quoting rules and then starts the agent.

The agent itself remains focused on MQTT control and on-demand live relay.
`wj-edge-ai-mvp.service` runs YOLO, YAMNet, and the clip uploader beside it,
using loopback media and local event files instead of opening a second MQTT
connection with the same device identity. Current deployment and validation
details are documented in `INTEGRATION_STATUS.md` and
`JETSON_HANDOFF_2026-07-23.md`.

## Install on Jetson (direct RTSPS)

The Jetson publishes directly to authenticated MediaMTX RTSPS on port 8322.
The legacy SSH local-forward remains installed only as rollback while the
server uses `rtspEncryption: optional`; it is not a normal service dependency.
One always-on FFmpeg process opens the
physical webcam and microphone and fans an encoded stream to four loopback UDP
ports. YOLO, YAMNet, the on-demand live relay, and the optional local RTSP
publisher each consume a separate local port, so they never compete for the
hardware. Only the live relay crosses the network, and it exists only between
`START_STREAM` and `STOP_STREAM`.

On the Jetson, from the repository checkout:

```bash
install -d -m 0700 /home/ssafy/.ssh
# Add lab.ssafy.com's independently verified host key to known_hosts first.
GIT_SSH_COMMAND='ssh -i /home/ssafy/.ssh/wj_gitlab_deploy -o IdentitiesOnly=yes' \
git clone git@lab.ssafy.com:s15-webmobile3-sub1/S15P11E201.git \
  /home/ssafy/william-james
cd /home/ssafy/william-james
git config core.sshCommand \
  'ssh -i /home/ssafy/.ssh/wj_gitlab_deploy -o IdentitiesOnly=yes'
git switch master
git pull --ff-only origin master
git rev-parse HEAD
cd ai/device_agent
chmod +x install-jetson.sh media-source.sh media-tunnel.sh check-jetson.sh \
  configure-jetson-rtsps.sh verify-mediamtx-rtsps.sh \
  diagnose-mediamtx-publish.sh
sudo ./install-jetson.sh
```

Use `device-agent.jetson.env.example` as the reference. Set the device ID and
operating bearer token returned by backend provisioning. Install the MQTT CA
and the public trust-anchor certificate used to validate MediaMTX; never copy
the server private key:

```bash
sudo install -m 0644 mqtt-ca.crt /etc/william-james/certs/mqtt-ca.crt
sudo install -m 0644 mediamtx-ca.crt \
  /etc/william-james/certs/mediamtx-ca.crt
sudo install -m 0600 jetson-mediamtx-credentials.env \
  /etc/william-james/jetson-mediamtx-credentials.env
sudo ./configure-jetson-rtsps.sh \
  --credentials-env /etc/william-james/jetson-mediamtx-credentials.env \
  --ca-cert /etc/william-james/certs/mediamtx-ca.crt \
  --ca-fingerprint-file mediamtx-ca.sha256
sudo -u williamjames ./verify-mediamtx-rtsps.sh
```

Set `MEDIA_TLS_CA_SHA256` to the CA certificate fingerprint confirmed through
a separate trusted channel. The verification script checks that fingerprint,
the certificate chain, and the `i15e201.p.ssafy.io` hostname before FFmpeg is
allowed to publish. Keep the following SSH material only for rollback:

```bash
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
the `ssh-keyscan` rollback entry. Then test the camera, broker, and direct RTSPS
endpoint and start the services:

```bash
sudo -u williamjames /opt/william-james/device-agent/check-jetson.sh
sudo -u williamjames \
  /opt/william-james/device-agent/diagnose-mediamtx-publish.sh
sudo systemctl start wj-media-source
# Only after the server confirms the final MQTT v2 ACL:
sudo systemctl restart wj-device-agent
sudo systemctl status wj-media-source wj-device-agent --no-pager
```

Neither `install-jetson.sh` nor `configure-jetson-rtsps.sh` restarts the agent.
The latter keeps `/etc/william-james/device-agent.env.rollback` and restores it
automatically when certificate, hostname, fingerprint, or FFmpeg TLS
verification fails. Do not pass `--restart` until the final MQTT v2 device ACL
has been checked on the running broker.

For a code rollback, use the revision recorded before installation:

```bash
previous="$(cat /opt/william-james/device-agent/PREVIOUS_DEPLOYED_COMMIT)"
cd /home/ssafy/william-james
git fetch origin master
git checkout --detach "$previous"
sudo ./ai/device_agent/install-jetson.sh
sudo -u williamjames /opt/william-james/device-agent/check-jetson.sh
sudo systemctl restart wj-device-agent
```

Return to the tracked deployment branch after the incident:

```bash
git switch master
git pull --ff-only origin master
```

The camera must be provisioned, claimed by the owner/admin account, and ONLINE.
Opening that camera's Live View in Flutter creates the stream; leaving the view
closes it. A missing client close is covered by the 45-second viewer TTL, the
backend idle stop, and the Jetson hard lease.

Run this command to enter the two-minute registration mode manually and print
the one-time code:

```bash
sudo -u williamjames \
  /opt/william-james/device-agent/registration-button.sh
```

Enter the displayed `XXXX-XXXX` value in App > Settings > Connect new device.
The command requires the one-time factory provisioning/enrollment flow to have
already stored an OPERATING bearer token in `device-agent.env`.

On Raspberry Pi, `prepare-pi.sh` also installs and starts
`wj-registration-button.service`. Wire a normally-open momentary button between
BCM GPIO 17 (physical pin 11) and GND. Pressing it runs the same registration
command without interactive `sudo`. The registration code is written to the
service journal:

```bash
journalctl -u wj-registration-button -f
```

To use another BCM GPIO number, override `REGISTRATION_BUTTON_GPIO` with
`systemctl edit wj-registration-button`, then restart the service. The service
runs as root only because `device-agent.env` is deliberately root-readable; the
button handler executes a fixed command and accepts no shell input.

Follow a real request with:

```bash
sudo journalctl -u wj-device-agent -f
pgrep -x -c ffmpeg
```

Do not use `pgrep -a`, `ps aux`, or verbose FFmpeg logging for the direct
publisher: Basic-auth credentials are part of FFmpeg's output URL and can
appear in process arguments or diagnostic output.

To roll back while the server still uses `rtspEncryption: optional`, reuse the
same publish-only MediaMTX credential through the encrypted SSH tunnel:

```bash
sudo systemctl enable --now wj-media-tunnel
sudo /opt/william-james/device-agent/configure-jetson-rtsps.sh \
  --scheme rtsp --host 127.0.0.1 --port 18554 --username wj-jetson-001
sudo systemctl restart wj-device-agent
```

There is always one FFmpeg process for the loopback-only shared media source.
Opening Live View adds one relay process; leaving the view removes only that
relay after the session's idle timeout. YOLO and YAMNet keep consuming their
local copies throughout.

If the configured camera device is absent during boot or temporarily
disconnected, `wj-media-source` stays active and waits instead of generating a
systemd restart loop. It resumes capture when the device becomes readable.

## Optional local RTSP and seven-day recording

The migration package keeps UDP ports 23000-23002 unchanged and adds port
23003 as MediaMTX's native MPEG-TS input. This avoids an extra FFmpeg
republisher and lets MediaMTX recover stream headers at the next keyframe.
MediaMTX listens only on `127.0.0.1:8554`, disables MoQ and its other network
servers, and exposes:

```text
rtsp://127.0.0.1:8554/homecam/main
rtsp://127.0.0.1:8554/homecam/ai
```

The recording worker reads `main`, copies H.264/AAC into one-minute MPEG-TS
segments, and the timer deletes only `homecam-*.ts` files older than seven
days. Both deletion and event extraction require the
`.homecam-recordings` safety marker.

`wj-event-prune.timer` separately bounds `/home/ssafy/ai_events`. Permanent
upload failures are retained for three days, other event bundles for seven
days, and diagnostic runs for three days. The event directory is capped at
2GiB and pruning also starts when filesystem free space falls below 4GiB.
Storage-pressure deletion order is blocked bundles, completed bundles, logs,
then pending events; files modified within the last 15 minutes are protected.
The event pruner requires the `.william-james-events` safety marker created by
`install-local-media.sh`.

During tests on the Jetson's current 64GB root disk,
`RECORDING_MAX_GIB=8` is a hard recording limit. When that limit is exceeded,
the pruning timer removes the oldest completed segments even if they are less
than seven days old. At the current 2.5Mbps video and 128kbps audio settings,
8GiB provides roughly 6-7 hours of recording while leaving space for the OS,
models, logs, and event clips.

Install the files without starting or switching any existing service:

```bash
cd ai/device_agent
chmod +x install-local-media.sh
sudo ./install-local-media.sh
```

Follow the activation commands printed by the installer. Verify both RTSP
paths before starting recording, then wait at least 70 seconds and verify that
a completed segment exists:

```bash
sudo -u williamjames \
  /opt/william-james/device-agent/check-local-media.sh
sudo systemctl status wj-event-prune.timer --no-pager
```

After a one-hour run, forced MediaMTX interruption, automatic recovery, and
resource checks pass, switch from `wj-edge-ai-mvp` to
`wj-edge-ai-recording`. The installer prints the exact rollback commands; the
original UDP consumers remain available throughout.

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

### Jetson Orin Nano I2C character LCD test

`lcd_test.py` drives the common PCF8574-backed HD44780 16x2 or 20x4 LCD with
the local `lgpio` library. On the developer kit's J12 header, use physical pin
3 for SDA, pin 5 for SCL, and pin 6 for GND. The Jetson signals are 3.3V-only.
If the LCD backpack is powered from physical pin 2 or 4 (5V), connect SDA and
SCL through a bidirectional I2C level shifter so the backpack pull-ups cannot
apply 5V to the Jetson.

Install the tools and inspect the bus before running the test:

```bash
sudo apt install i2c-tools python3-lgpio
ls -l /dev/i2c-*
sudo i2cdetect -y 7
```

JetPack 6.x commonly exposes J12 pins 3 and 5 as `/dev/i2c-7`, but use the bus
number and address shown on the target device. Most backpacks respond at
`0x27` or `0x3f`.

```bash
cd ai/device_agent
python3 lcd_test.py
python3 lcd_test.py --bus 7 --address 0x3f --columns 20 \
  --line1 "Jetson Orin Nano" --line2 "I2C LCD OK"
```

The LCD keeps the written text after the command exits. A standard HD44780
character ROM cannot display Korean, so the test replaces unsupported
characters with `?`.

### Jetson registration button with LCD

`jetson_registration_button.py` requests the existing two-minute registration
code and shows it on the LCD. On the current Orin Nano developer kit, physical
pin 7 is `gpiochip0` line 144 (`PAC.06`). Wire a normally-open button between
physical pin 7 and GND pin 6. The service requests an internal pull-up; an
external 10 kohm pull-up from pin 7 to 3.3V is recommended for long wires.
Never pull the button input up to 5V.

The LCD stays on physical pins 3 and 5. If its backpack uses 5V, put a
bidirectional I2C level shifter between the LCD and the Jetson's 3.3V-only SDA
and SCL signals. Confirm the current mapping before enabling the service:

```bash
gpioinfo | grep PAC.06
sudo i2cdetect -y -r 7
```

Install the checked-out code and enable the optional service only after the
device has an OPERATING bearer token:

```bash
cd ai/device_agent
sudo apt install python3-lgpio i2c-tools
sudo ./install-jetson.sh
sudo systemctl enable --now wj-registration-button-jetson
sudo journalctl -u wj-registration-button-jetson -f
```

The LCD shows `Press button`, then `Requesting code`, followed by the issued
`XXXX-XXXX` value. At the server-provided expiry time (normally two minutes),
the LCD replaces the stale code with `Code expired` / `Press button`. Issuing a
new code cancels the previous expiry timer.

A failed request shows `Registration` / `Failed`, then after
`REGISTRATION_FAILURE_REASON_SECONDS` (default 3) the reason, and after a
further `REGISTRATION_FAILURE_READY_SECONDS` (default 5) it returns to
`Press button` / `to register` so the code can be requested again. Pressing the
button during the sequence cancels the remaining steps.

Only an already-registered device gets a specific reason,
`Device already` / `registered`, because it is the one cause the person at the
device can act on. Every other cause — a rejected token, a server fault, an
unreachable network — shows `Temporary error` / `Try again later`, so the LCD
never exposes why the request was refused. The rejected status and error code
stay in the journal:

```
Registration request failed: Registration command failed with exit code 1: \
RuntimeError: 서버가 요청을 거부했습니다 (401, DEVICE_AUTHENTICATION_FAILED)
```

Override `REGISTRATION_BUTTON_CHIP`, `REGISTRATION_BUTTON_LINE`,
`LCD_I2C_BUS`, `LCD_I2C_ADDRESS`, `LCD_COLUMNS`,
`REGISTRATION_FAILURE_REASON_SECONDS`, or
`REGISTRATION_FAILURE_READY_SECONDS` in
`/etc/william-james/device-agent.env` when the target differs.

To issue one code and show it on the LCD without a physical button, stop the
button service temporarily and run the same program once:

```bash
sudo systemctl stop wj-registration-button-jetson
sudo /usr/bin/python3 \
  /opt/william-james/device-agent/jetson_registration_button.py --once
sudo systemctl start wj-registration-button-jetson
```

In `--once` mode the process remains active until the code expires, updates the
LCD to the expired message, and then exits.

### Jetson PCA9685 servo test

Use a PCA9685 rather than driving an SG90 directly from a Jetson GPIO. Connect
PCA9685 `VCC` to Jetson 3.3V, SDA/SCL to physical pins 3/5, and GND to Jetson
GND. Connect the servo signal to PCA9685 channel 0. Power PCA9685 `V+` and the
servo from a separate regulated 5V supply, and join that supply's GND to Jetson
GND. Do not power the servo from the Jetson 3.3V or 5V header.

The LCD and PCA9685 can share the I2C bus because their normal addresses differ:

```text
LCD      0x27 (sometimes 0x3f)
PCA9685  0x40
```

Scan first, disconnect the servo horn or unload the mechanism, and run only the
conservative 1200-1800 microsecond test range:

```bash
sudo i2cdetect -y -r 7
cd ai/device_agent
sudo python3 servo_test.py \
  --bus 7 --address 0x40 --channel 0 \
  --pulses 1500 1200 1500 1800 1500
```

The script disables channel output when it finishes. Use `--keep-powered` only
when holding the final position is intentional. Do not expand toward the
allowed 500-2500 microsecond software limits until the physical mechanism's
safe endpoints have been measured.

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
