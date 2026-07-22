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

The agent does not run YOLO/YAMNet and does not create event clips. Those
components use the same device identity and publish `/events`; integration rules
are documented in `INTEGRATION_STATUS.md`.

## Install on Jetson (current production server)

The production RTSP port is intentionally bound to server loopback. The Jetson
therefore uses an authenticated SSH local-forward, just like
`backend/demo/start-webcam-live.ps1`. The SSH connection can remain idle, but
FFmpeg and camera traffic exist only between `START_STREAM` and `STOP_STREAM`.

On the Jetson, from the repository checkout:

```bash
cd ai/device_agent
chmod +x install-jetson.sh media-tunnel.sh check-jetson.sh
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
sudo systemctl start wj-media-tunnel
sudo -u williamjames /opt/william-james/device-agent/check-jetson.sh
sudo systemctl start wj-device-agent
sudo systemctl status wj-media-tunnel wj-device-agent --no-pager
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

There should be no FFmpeg process before Live View opens, one while it is being
watched, and none after the session's idle timeout.

## Install on Raspberry Pi

```bash
sudo mkdir -p /opt/william-james/device-agent /etc/william-james/certs
sudo cp -r ai/device_agent/wj_device_agent ai/device_agent/requirements.txt \
  /opt/william-james/device-agent/
sudo python3 -m venv /opt/william-james/device-agent/venv
sudo /opt/william-james/device-agent/venv/bin/pip install \
  -r /opt/william-james/device-agent/requirements.txt
sudo cp ai/device_agent/device-agent.env.example \
  /etc/william-james/device-agent.env
sudo chmod 600 /etc/william-james/device-agent.env
sudo cp ai/device_agent/wj-device-agent.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wj-device-agent
```

Copy the MQTT CA certificate to the path configured by `MQTT_CA_CERT`, then set
the enrollment response values:

```text
DEVICE_ID=<deviceId>
DEVICE_BEARER_TOKEN=<OPERATING bearerToken>
MQTT_HOST=<broker DNS name>
MQTT_PORT=8883
```

`MEDIA_PUBLISH_URL_TEMPLATE` must contain exactly one `{stream_id}` placeholder.
For a temporary SSH tunnel use:

```text
rtsp://127.0.0.1:8554/live/{stream_id}
```

For direct production publishing in a future deployment, first configure and
expose authenticated RTSPS on MediaMTX, then use a URL such as:

```text
rtsps://device-user:password@media.example.com:8322/live/{stream_id}
```

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
logs.
