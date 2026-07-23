# Raspberry Pi provisioning and direct RTSPS runbook

This runbook reproduces the deployed Raspberry Pi control and media layout
without storing any device, MQTT, or MediaMTX secret in Git.

## Resulting topology

```text
EC2 Spring backend
  -> MQTT START_STREAM on TLS port 8883
  -> Raspberry Pi wj-device-agent
  -> reads rtsp://127.0.0.1:8554/homecam
  -> publishes authenticated RTSPS to EC2 port 8322
  -> EC2 MediaMTX produces protected HLS for Flutter

USB camera
  -> homecam-publisher
  -> loopback-only Raspberry Pi MediaMTX
```

The Pi does not open an SSH media tunnel. MQTT and RTSPS are independent TLS
connections initiated by the Pi.

## What is safe to commit

The repository contains code, example configuration, service units, and public
server addresses. It must not contain any of the following:

- `DEVICE_PROVISIONING_ADMIN_KEY`
- bootstrap or operating bearer tokens
- MediaMTX publish passwords
- SSH private keys
- populated `/etc/william-james/*.env` files

## 1. Prepare the Pi before issuing a bootstrap token

Clone the repository and run the installer with the MQTT CA certificate. The
installer supports 64-bit ARM Raspberry Pi OS and also maps x86-64 for local
testing.

```bash
git clone https://lab.ssafy.com/s15-webmobile3-sub1/S15P11E201.git
cd S15P11E201/ai/device_agent

chmod +x scripts/*.sh homecam-publisher.sh
sudo ./scripts/prepare-pi.sh /path/to/mqtt-ca.crt
```

This installs:

- the Python device agent under `/opt/william-james/device-agent`
- MediaMTX v1.18.2 with its published SHA-256 checksum verified
- loopback RTSP on `127.0.0.1:8554`
- `wj-device-agent.service`
- `mediamtx.service`
- `homecam-publisher.service`
- root-owned example configuration under `/etc/william-james`

`wj-device-agent` is deliberately left stopped until enrollment. MediaMTX is
started immediately. The camera publisher is enabled for boot but not started
by the installer.

## 2. Configure direct EC2 RTSPS publishing

Get the publish-only MediaMTX username and password from the EC2 infrastructure
administrator. On the Pi, enter them through the hidden prompt:

```bash
cd ~/S15P11E201/ai/device_agent
sudo ./scripts/configure-pi-rtsps.sh
```

For non-interactive factory provisioning, put only the password in a mode-600
file and pass the username separately:

```bash
chmod 600 /secure/path/mediamtx-password
sudo ./scripts/configure-pi-rtsps.sh \
  --username wj-pi-001 \
  --password-file /secure/path/mediamtx-password
```

The helper percent-encodes credentials and atomically updates
`MEDIA_PUBLISH_URL_TEMPLATE`. It never prints the password or the completed
URL.

## 3. Create the unclaimed device on EC2

Do this only after the Pi is prepared. The bootstrap token expires quickly.
First obtain the hardware serial on the Pi:

```bash
awk -F ': ' '/^Serial/ {print $2}' /proc/cpuinfo
```

Then run the helper on the EC2 host where the internal API is reachable,
substituting that value into `--serial`:

```bash
cd ~/william-james/ai/device_agent
set -a
source ~/william-james/secrets/app.env
set +a

./scripts/create-device-on-server.sh \
  --serial "WJ-PI-10000000E127F417" \
  --name "Living Room Raspberry Pi" \
  --model "Raspberry Pi 4" \
  --token-out /secure/path/wj-bootstrap.token
```

The helper prints only the device ID and expiry. It writes the bearer token to
the requested mode-600 file and refuses to overwrite an existing file.

Transfer that single token file to `/home/pi/wj-bootstrap.token` using an
approved secure channel. Do not paste it into shell history or chat.

## 4. Enroll, start MQTT, and claim in Flutter

On the Pi:

```bash
chmod 600 /home/pi/wj-bootstrap.token
cd ~/S15P11E201/ai/device_agent
sudo ./scripts/enroll-pi.sh /home/pi/wj-bootstrap.token
```

The script:

1. exchanges the one-use bootstrap credential over HTTPS;
2. atomically writes the operating device ID and bearer token with mode 600;
3. deletes the bootstrap token after a successful exchange;
4. validates the MQTT CA and runtime configuration;
5. enables and starts `wj-device-agent`;
6. prints a two-minute Flutter registration code.

Enter that code in the app immediately. Enrollment authenticates the machine;
the registration code separately assigns that machine to a user account.

## 5. Connect and start the USB camera

List the actual capture devices and supported modes:

```bash
v4l2-ctl --list-devices
v4l2-ctl --device=/dev/video0 --list-formats-ext
ls -l /dev/v4l/by-id/ 2>/dev/null || true
```

Prefer a stable `/dev/v4l/by-id/...-video-index0` path. Update:

```bash
sudoedit /etc/william-james/homecam-publisher.env
```

Then start and verify the publisher:

```bash
sudo systemctl start homecam-publisher
sudo systemctl status homecam-publisher mediamtx --no-pager -l

ffprobe -v error -rtsp_transport tcp \
  -show_entries stream=codec_type,codec_name,width,height \
  -of default=noprint_wrappers=1 \
  rtsp://127.0.0.1:8554/homecam
```

The local stream must report H.264 before testing Flutter Live View. A board
with no `/dev/video0` and `rpicam-vid --list-cameras` reporting no camera can
complete MQTT enrollment, but it cannot publish video.

## 6. Validate the complete Pi configuration

```bash
cd ~/S15P11E201/ai/device_agent
sudo ./scripts/check-pi.sh
```

Expected MQTT log:

```text
MQTT connected and command subscription active
```

Open the camera in Flutter while following:

```bash
sudo journalctl -u wj-device-agent -f
sudo journalctl -u mediamtx -f
```

The device agent should receive `START_STREAM`, start one relay FFmpeg process,
and publish `STREAM_READY`. The always-on `homecam-publisher` remains the only
process that opens the physical camera.

## Credential rotation

Before `DEVICE_CREDENTIAL_EXPIRES_AT`, rotate the operating credential and
restart the service:

```bash
sudo /opt/william-james/device-agent/venv/bin/python \
  -m wj_device_agent.provision \
  --api-base-url https://i15e201.p.ssafy.io \
  --env-file /etc/william-james/device-agent.env \
  rotate

sudo systemctl restart wj-device-agent
```

Rotation changes both the API bearer token and the Mosquitto password for that
device. It does not require re-claiming the device in Flutter.

## Security cleanup

After validation:

- delete any transferred bootstrap or temporary password file;
- change factory/default Pi passwords;
- keep `/etc/william-james/device-agent.env` mode 600;
- keep MediaMTX publish credentials out of command-line arguments and logs;
- do not expose the Pi's loopback MediaMTX port on the LAN or Internet.
