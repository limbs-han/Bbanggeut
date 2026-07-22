#!/usr/bin/env bash
set -euo pipefail

exec ffmpeg -hide_banner -loglevel warning \
  -f v4l2 -input_format mjpeg -framerate 20 -video_size 1280x720 \
  -i /dev/video0 -an \
  -c:v libx264 -preset ultrafast -tune zerolatency \
  -pix_fmt yuv420p -b:v 1800k -maxrate 2200k -bufsize 3600k \
  -g 40 -keyint_min 40 -sc_threshold 0 \
  -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/homecam
