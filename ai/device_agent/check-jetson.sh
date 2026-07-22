#!/usr/bin/env bash

set -Eeuo pipefail

ENV_FILE="${1:-/etc/william-james/device-agent.env}"
if [[ ! -r "$ENV_FILE" ]]; then
    echo "Environment file is not readable: ${ENV_FILE}" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

failures=0
check() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '[OK]   %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label" >&2
        failures=$((failures + 1))
    fi
}

CAMERA_DEVICE="${CAMERA_DEVICE:-/dev/video0}"
CAMERA_WIDTH="${CAMERA_WIDTH:-1280}"
CAMERA_HEIGHT="${CAMERA_HEIGHT:-720}"
CAMERA_FPS="${CAMERA_FPS:-30}"
CAMERA_INPUT_FORMAT="${CAMERA_INPUT_FORMAT:-mjpeg}"
FFMPEG_PATH="${FFMPEG_PATH:-/usr/bin/ffmpeg}"
MEDIA_TUNNEL_LOCAL_PORT="${MEDIA_TUNNEL_LOCAL_PORT:-18554}"

check "FFmpeg executable" test -x "$FFMPEG_PATH"
check "camera device ${CAMERA_DEVICE}" test -r "$CAMERA_DEVICE"
check "MQTT CA certificate" test -r "${MQTT_CA_CERT:-/missing}"
check "media SSH key" test -r "${MEDIA_SSH_KEY:-/missing}"
check "media SSH known_hosts" test -r "${MEDIA_SSH_KNOWN_HOSTS:-/missing}"
check "MQTT TLS port ${MQTT_HOST:-missing}:${MQTT_PORT:-8883}" \
    timeout 5 bash -c "</dev/tcp/${MQTT_HOST:-missing}/${MQTT_PORT:-8883}"
check "local MediaMTX tunnel port ${MEDIA_TUNNEL_LOCAL_PORT}" \
    timeout 3 bash -c "</dev/tcp/127.0.0.1/${MEDIA_TUNNEL_LOCAL_PORT}"

if [[ -x "$FFMPEG_PATH" && -r "$CAMERA_DEVICE" ]]; then
    check "one-second camera capture" timeout 8 "$FFMPEG_PATH" \
        -hide_banner -loglevel error \
        -f v4l2 -input_format "$CAMERA_INPUT_FORMAT" \
        -framerate "$CAMERA_FPS" -video_size "${CAMERA_WIDTH}x${CAMERA_HEIGHT}" \
        -i "$CAMERA_DEVICE" -t 1 -an -f null -
fi

if (( failures > 0 )); then
    printf '%s check(s) failed. Fix them before opening Live View.\n' "$failures" >&2
    exit 1
fi
echo "Jetson camera and server prerequisites are ready."
