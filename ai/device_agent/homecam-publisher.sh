#!/usr/bin/env bash
set -euo pipefail

camera_device="${CAMERA_DEVICE:-/dev/video0}"
input_format="${CAMERA_INPUT_FORMAT:-mjpeg}"
fps="${CAMERA_FPS:-20}"
width="${CAMERA_WIDTH:-1280}"
height="${CAMERA_HEIGHT:-720}"
bitrate="${VIDEO_BITRATE:-1800k}"
maxrate="${VIDEO_MAXRATE:-2200k}"
bufsize="${VIDEO_BUFSIZE:-3600k}"
publish_url="${LOCAL_RTSP_URL:-rtsp://127.0.0.1:8554/homecam}"

if [[ ! -e "$camera_device" ]]; then
  echo "Camera device is not present: $camera_device" >&2
  echo "Connect the camera, update /etc/william-james/homecam-publisher.env, then start this service." >&2
  exit 0
fi

exec /usr/bin/ffmpeg \
  -hide_banner \
  -nostdin \
  -loglevel warning \
  -f v4l2 \
  -input_format "$input_format" \
  -framerate "$fps" \
  -video_size "${width}x${height}" \
  -i "$camera_device" \
  -an \
  -c:v libx264 \
  -preset ultrafast \
  -tune zerolatency \
  -pix_fmt yuv420p \
  -b:v "$bitrate" \
  -maxrate "$maxrate" \
  -bufsize "$bufsize" \
  -g "$((fps * 2))" \
  -keyint_min "$((fps * 2))" \
  -sc_threshold 0 \
  -f rtsp \
  -rtsp_transport tcp \
  "$publish_url"
