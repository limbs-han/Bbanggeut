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

For direct production publishing, configure authenticated RTSPS on MediaMTX and
use a URL such as:

```text
rtsps://device-user:password@media.example.com:8322/live/{stream_id}
```

## Jetson adapter

The default FFmpeg input uses Raspberry Pi V4L2. A Jetson can replace the input
and encoder without changing MQTT logic by setting JSON argument arrays:

```text
FFMPEG_INPUT_ARGS=["-f","v4l2","-framerate","30","-video_size","1280x720","-i","/dev/video0"]
FFMPEG_VIDEO_ARGS=["-c:v","h264_v4l2m2m","-b:v","2500k","-g","60"]
```

Use arguments verified on the target JetPack release; NVIDIA CSI/DeepStream
pipelines can instead expose a local RTSP source and configure FFmpeg to copy it.

## Operations

```bash
sudo systemctl status wj-device-agent
sudo journalctl -u wj-device-agent -f
sudo systemctl restart wj-device-agent
```

The service deliberately suppresses FFmpeg stderr because publish URLs can
contain credentials. Add a redacting log collector before enabling FFmpeg debug
logs.
