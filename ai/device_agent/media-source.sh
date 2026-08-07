#!/usr/bin/env bash

# Open the physical webcam/microphone exactly once and fan the encoded stream
# out to loopback-only MPEG-TS consumers. Ports 23000-23002 preserve the
# validated UDP fallback; the fourth output feeds MediaMTX's native MPEG-TS
# input without opening or encoding the BRIO a second time.

set -Eeuo pipefail

: "${FFMPEG_PATH:=/usr/bin/ffmpeg}"
: "${CAMERA_DEVICE:=/dev/video0}"
: "${CAMERA_INPUT_FORMAT:=mjpeg}"
: "${CAMERA_WIDTH:=1280}"
: "${CAMERA_HEIGHT:=720}"
: "${CAMERA_FPS:=30}"
: "${AUDIO_DEVICE:=plughw:CARD=B100,DEV=0}"
: "${VIDEO_BITRATE:=2500k}"
: "${CAMERA_WAIT_SECONDS:=5}"
: "${AUDIO_WAIT_SECONDS:=3}"
: "${AUDIO_WAIT_ATTEMPTS:=20}"
: "${YOLO_UDP_PORT:=23000}"
: "${YAMNET_UDP_PORT:=23001}"
: "${LIVE_UDP_PORT:=23002}"
: "${LOCAL_RTSP_UDP_PORT:=23003}"

declare -A seen_ports=()
for port in \
    "$YOLO_UDP_PORT" \
    "$YAMNET_UDP_PORT" \
    "$LIVE_UDP_PORT" \
    "$LOCAL_RTSP_UDP_PORT"; do
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
        echo "Invalid loopback UDP port: ${port}" >&2
        exit 2
    fi
    if [[ -n "${seen_ports[$port]:-}" ]]; then
        echo "Loopback UDP ports must be unique: ${port}" >&2
        exit 2
    fi
    seen_ports["$port"]=1
done

for name in CAMERA_WAIT_SECONDS AUDIO_WAIT_SECONDS AUDIO_WAIT_ATTEMPTS; do
    if ! [[ "${!name}" =~ ^[1-9][0-9]*$ ]]; then
        echo "${name} must be a positive integer" >&2
        exit 2
    fi
done

waiting_for_camera=false
while [[ ! -r "$CAMERA_DEVICE" ]]; do
    if [[ "$waiting_for_camera" == false ]]; then
        echo "Camera device is not readable; waiting for connection: ${CAMERA_DEVICE}" >&2
        waiting_for_camera=true
    fi
    sleep "$CAMERA_WAIT_SECONDS"
done
if [[ "$waiting_for_camera" == true ]]; then
    echo "Camera device is available: ${CAMERA_DEVICE}"
fi

# 카메라 노드가 열린다고 마이크까지 준비된 것은 아니다. ffmpeg 는 두 장치를 한
# 프로세스에서 열기 때문에 마이크 하나 때문에 영상까지 통째로 죽는다. 특히 직전
# 인스턴스가 SIGKILL 로 끝난 직후에는 ALSA 가 장치를 아직 반납하지 않아 "Device
# or resource busy" 가 난다. 여기서 기다리지 않으면 systemd 가 몇 초마다 같은
# 실패를 반복한다.
if command -v arecord >/dev/null 2>&1; then
    audio_attempt=0
    waiting_for_audio=false
    while ! arecord -q -D "$AUDIO_DEVICE" -f S16_LE -r 48000 -c 1 -d 1 \
        /dev/null >/dev/null 2>&1; do
        audio_attempt=$(( audio_attempt + 1 ))
        if (( audio_attempt >= AUDIO_WAIT_ATTEMPTS )); then
            echo "Audio device did not become available: ${AUDIO_DEVICE}" >&2
            exit 1
        fi
        if [[ "$waiting_for_audio" == false ]]; then
            echo "Audio device is not available; waiting: ${AUDIO_DEVICE}" >&2
            waiting_for_audio=true
        fi
        sleep "$AUDIO_WAIT_SECONDS"
    done
    if [[ "$waiting_for_audio" == true ]]; then
        echo "Audio device is available: ${AUDIO_DEVICE}"
    fi
else
    echo "arecord is unavailable; skipping the audio readiness check." >&2
fi

tee_outputs="[f=mpegts:onfail=ignore]udp://127.0.0.1:${YOLO_UDP_PORT}?pkt_size=1316"
tee_outputs+="|[f=mpegts:onfail=ignore]udp://127.0.0.1:${YAMNET_UDP_PORT}?pkt_size=1316"
tee_outputs+="|[f=mpegts:onfail=ignore]udp://127.0.0.1:${LIVE_UDP_PORT}?pkt_size=1316"
tee_outputs+="|[f=mpegts:onfail=ignore]udp://127.0.0.1:${LOCAL_RTSP_UDP_PORT}?pkt_size=1316"

exec "$FFMPEG_PATH" \
    -hide_banner -nostdin -loglevel warning -copyts \
    -thread_queue_size 1024 \
    -f v4l2 -input_format "$CAMERA_INPUT_FORMAT" \
    -timestamps abs \
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
    -af "aresample=async=1" \
    -f tee "$tee_outputs"
