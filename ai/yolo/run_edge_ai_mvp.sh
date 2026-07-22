#!/usr/bin/env bash

# Minimal Jetson AI stack:
# - YOLO prints simulated pan/tilt directions.
# - YAMNet creates a local laughter trigger and +/- 5 second audio.
# - YOLO creates the matching +/- 5 second video.
# - The uploader muxes and uploads the 10 second MP4 through the device API.
#
# This stack intentionally does not create another MQTT connection. The
# wj-device-agent remains the single owner of the provisioned MQTT identity.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YAMNET_DIR="${YAMNET_DIR:-${SCRIPT_DIR}/../yamnet}"
YOLO_PYTHON="${YOLO_PYTHON:-${HOME}/venvs/yolo/bin/python}"
YAMNET_PYTHON="${YAMNET_PYTHON:-${HOME}/venvs/yamnet/bin/python}"
EVENT_DIR="${EVENT_DIR:-${HOME}/ai_events}"
CLIP_SECONDS="${CLIP_SECONDS:-5}"
ENV_FILE="${DEVICE_AGENT_ENV_FILE:-/etc/william-james/device-agent.env}"

if [[ -r "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

: "${DEVICE_ID:?DEVICE_ID is required (normally from device-agent.env)}"
: "${DEVICE_BEARER_TOKEN:?DEVICE_BEARER_TOKEN is required (normally from device-agent.env)}"
: "${API_BASE_URL:=https://i15e201.p.ssafy.io}"
: "${YOLO_SOURCE_URL:=udp://127.0.0.1:23000?fifo_size=1000000&overrun_nonfatal=1}"
: "${YAMNET_SOURCE_URL:=udp://127.0.0.1:23001?fifo_size=1000000&overrun_nonfatal=1}"
: "${YAMNET_THRESHOLD:=0.05}"
: "${YAMNET_CONSECUTIVE:=2}"

for required in \
    "$YOLO_PYTHON" \
    "$YAMNET_PYTHON" \
    "${SCRIPT_DIR}/yolov8_autoframe_jetson.py" \
    "${SCRIPT_DIR}/laughter_clip_uploader.py" \
    "${YAMNET_DIR}/yamnet_laughter_detect_jetson.py"; do
    if [[ ! -e "$required" ]]; then
        echo "Required file not found: $required" >&2
        exit 1
    fi
done

mkdir -p "$EVENT_DIR"
RUN_DIR="${EVENT_DIR}/logs/$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$RUN_DIR"

declare -a PIDS=()
cleanup() {
    local status="$?"
    trap - EXIT INT TERM
    for pid in "${PIDS[@]}"; do
        kill -INT "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    exit "$status"
}
trap cleanup EXIT INT TERM

echo "Starting edge AI MVP for device ${DEVICE_ID}"
echo "YOLO directions and YAMNet detections will appear below."
echo "Event clips: ${EVENT_DIR}"
echo "AI remains active whether Live View is open or closed."

"$YOLO_PYTHON" -u "${SCRIPT_DIR}/laughter_clip_uploader.py" \
    --event-dir "$EVENT_DIR" \
    --api-base-url "$API_BASE_URL" \
    > >(sed -u 's/^/[UPLOAD] /' | tee -a "${RUN_DIR}/uploader.log") 2>&1 &
PIDS+=("$!")

YAMNET_COMMAND=(
    "$YAMNET_PYTHON" -u "${YAMNET_DIR}/yamnet_laughter_detect_jetson.py"
    --device-id "$DEVICE_ID"
    --stream-url "$YAMNET_SOURCE_URL"
    --threshold "$YAMNET_THRESHOLD"
    --consecutive "$YAMNET_CONSECUTIVE"
    --cooldown 12
    --gain 1.5
    --event-dir "$EVENT_DIR"
    --clip-seconds "$CLIP_SECONDS"
)
MQTT_HOST= "${YAMNET_COMMAND[@]}" \
    > >(sed -u 's/^/[YAMNET] /' | tee -a "${RUN_DIR}/yamnet.log") 2>&1 &
PIDS+=("$!")

YOLO_COMMAND=(
    "$YOLO_PYTHON" -u "${SCRIPT_DIR}/yolov8_autoframe_jetson.py"
    --stream-url "$YOLO_SOURCE_URL"
    --device-id "$DEVICE_ID"
    --event-dir "$EVENT_DIR"
    --clip-seconds "$CLIP_SECONDS"
    --control-output "${RUN_DIR}/autoframe_commands.jsonl"
)
MQTT_HOST= "${YOLO_COMMAND[@]}" \
    > >(sed -u 's/^/[YOLO] /' | tee -a "${RUN_DIR}/yolo.log") 2>&1 &
PIDS+=("$!")

while true; do
    for pid in "${PIDS[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"
            exit $?
        fi
    done
    sleep 1
done
