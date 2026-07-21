#!/usr/bin/env bash
set -euo pipefail

output=/tmp/homecam-encode-test.mp4
rm -f "$output"

timeout 12 ffmpeg -hide_banner -loglevel warning \
  -f v4l2 -input_format mjpeg -framerate 30 -video_size 1280x720 \
  -i /dev/video0 -an -c:v libx264 -preset ultrafast -tune zerolatency \
  -pix_fmt yuv420p -b:v 2500k -g 60 \
  -t 5 -y "$output"

ls -lh "$output"
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,avg_frame_rate \
  -of default=noprint_wrappers=1 "$output"
