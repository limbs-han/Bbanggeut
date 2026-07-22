#!/usr/bin/env bash

# Open the physical webcam/microphone exactly once and fan the encoded stream
# out to three loopback-only MPEG-TS consumers: YOLO, YAMNet, and live relay.

set -Eeuo pipefail

: "${FFMPEG_PATH:=/usr/bin/ffmpeg}"
: "${CAMERA_DEVICE:=/dev/video0}"
: "${CAMERA_INPUT_FORMAT:=mjpeg}"
: "${CAMERA_WIDTH:=1280}"
: "${CAMERA_HEIGHT:=720}"
: "${CAMERA_FPS:=30}"
: "${AUDIO_DEVICE:=plughw:CARD=B100,DEV=0}"
: "${VIDEO_BITRATE:=2500k}"
: "${YOLO_UDP_PORT:=23000}"
: "${YAMNET_UDP_PORT:=23001}"
: "${LIVE_UDP_PORT:=23002}"

for port in "$YOLO_UDP_PORT" "$YAMNET_UDP_PORT" "$LIVE_UDP_PORT"; do
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
        echo "Invalid loopback UDP port: ${port}" >&2
        exit 2
    fi
done

tee_outputs="[f=mpegts:onfail=ignore]udp://127.0.0.1:${YOLO_UDP_PORT}?pkt_size=1316"
tee_outputs+="|[f=mpegts:onfail=ignore]udp://127.0.0.1:${YAMNET_UDP_PORT}?pkt_size=1316"
tee_outputs+="|[f=mpegts:onfail=ignore]udp://127.0.0.1:${LIVE_UDP_PORT}?pkt_size=1316"

exec "$FFMPEG_PATH" \
    -hide_banner -nostdin -loglevel warning \
    -thread_queue_size 1024 \
    -f v4l2 -input_format "$CAMERA_INPUT_FORMAT" \
    -framerate "$CAMERA_FPS" -video_size "${CAMERA_WIDTH}x${CAMERA_HEIGHT}" \
    -i "$CAMERA_DEVICE" \
    -thread_queue_size 1024 \
    -f alsa -ac 1 -ar 48000 -i "$AUDIO_DEVICE" \
    -map 0:v:0 -map 1:a:0 \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -pix_fmt yuv420p -profile:v baseline -x264-params repeat-headers=1 \
    -g "$CAMERA_FPS" -keyint_min "$CAMERA_FPS" -sc_threshold 0 -bf 0 \
    -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_BITRATE" -bufsize 5000k \
    -c:a aac -b:a 128k -ar 48000 -ac 1 \
    -af aresample=async=1:first_pts=0 \
    -f tee "$tee_outputs"
