#!/usr/bin/env bash

# Disk-backed Jetson AI stack:
# - YOLO and YAMNet consume the validated shared RTSP path.
# - YAMNet writes lightweight trigger JSON only.
# - The uploader merges laughs within 30 seconds and extracts the first
#   detection -60 seconds through the last detection +60 seconds from the
#   compressed rolling MPEG-TS segments.
#
# Keep run_edge_ai_mvp.sh available as the 5-second UDP fallback.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YAMNET_DIR="${YAMNET_DIR:-${SCRIPT_DIR}/../yamnet}"
YOLO_PYTHON="${YOLO_PYTHON:-${HOME}/venvs/yolo/bin/python}"
YAMNET_PYTHON="${YAMNET_PYTHON:-${HOME}/venvs/yamnet/bin/python}"
EVENT_DIR="${EVENT_DIR:-${HOME}/ai_events}"
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
: "${LOCAL_RTSP_AI_URL:=rtsp://127.0.0.1:8554/homecam/ai}"
: "${RECORDING_DIR:=/var/lib/william-james/recordings}"
: "${RECORDING_SEGMENT_SECONDS:=60}"
: "${EVENT_CLIP_SECONDS:=60}"
: "${EVENT_MERGE_GAP_SECONDS:=30}"
: "${DELETE_EVENT_AFTER_UPLOAD:=true}"
: "${LOCAL_MQTT_HOST:=127.0.0.1}"
: "${LOCAL_MQTT_PORT:=1883}"
: "${YOLO_DEADZONE_WIDTH:=0.08}"
: "${YOLO_DEADZONE_HEIGHT:=0.08}"
: "${SERVO_DASHBOARD_HOST:=0.0.0.0}"
: "${SERVO_DASHBOARD_PORT:=8765}"
: "${SERVO_DASHBOARD_FRAME_WIDTH:=960}"
: "${SERVO_DASHBOARD_JPEG_QUALITY:=72}"
: "${SERVO_DASHBOARD_FRAME_INTERVAL_SECONDS:=0.2}"
: "${YAMNET_SCORE_AGGREGATION:=mean}"
: "${YAMNET_THRESHOLD:=0.125}"
: "${YAMNET_CONSECUTIVE:=3}"
: "${YAMNET_COOLDOWN:=12}"
: "${YAMNET_GAIN:=1.5}"
: "${UPLOAD_RETRY_INITIAL_SECONDS:=5}"
: "${UPLOAD_RETRY_MAX_SECONDS:=300}"

YAMNET_SCORE_AGGREGATION="${YAMNET_SCORE_AGGREGATION,,}"
case "$YAMNET_SCORE_AGGREGATION" in
    max|mean|p90)
        ;;
    *)
        echo \
            "YAMNET_SCORE_AGGREGATION must be one of: max, mean, p90" \
            >&2
        exit 2
        ;;
esac
if [[ ! "$YAMNET_CONSECUTIVE" =~ ^[1-9][0-9]*$ ]]; then
    echo "YAMNET_CONSECUTIVE must be a positive integer" >&2
    exit 2
fi

for required in \
    "$YOLO_PYTHON" \
    "$YAMNET_PYTHON" \
    "${SCRIPT_DIR}/yolov8_autoframe_jetson.py" \
    "${SCRIPT_DIR}/segment_clip_uploader.py" \
    "${YAMNET_DIR}/yamnet_laughter_detect_jetson.py" \
    "${RECORDING_DIR}/.homecam-recordings"; do
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

echo "Starting disk-backed edge AI for device ${DEVICE_ID}"
echo "AI source: loopback RTSP"
echo "Rolling recordings: ${RECORDING_DIR}"
echo "Event clips: ${EVENT_DIR}"
echo \
    "YAMNet detector: aggregation=${YAMNET_SCORE_AGGREGATION} " \
    "threshold=${YAMNET_THRESHOLD} consecutive=${YAMNET_CONSECUTIVE} " \
    "cooldown=${YAMNET_COOLDOWN}s gain=${YAMNET_GAIN}"
echo \
    "Upload retry: initial=${UPLOAD_RETRY_INITIAL_SECONDS}s " \
    "maximum=${UPLOAD_RETRY_MAX_SECONDS}s; terminal 4xx is quarantined"

UPLOADER_COMMAND=(
    "$YOLO_PYTHON" -u "${SCRIPT_DIR}/segment_clip_uploader.py"
    --event-dir "$EVENT_DIR"
    --recording-dir "$RECORDING_DIR"
    --api-base-url "$API_BASE_URL"
    --merge-gap-seconds "$EVENT_MERGE_GAP_SECONDS"
    --segment-seconds "$RECORDING_SEGMENT_SECONDS"
    --retry-initial-seconds "$UPLOAD_RETRY_INITIAL_SECONDS"
    --retry-max-seconds "$UPLOAD_RETRY_MAX_SECONDS"
)
case "${DELETE_EVENT_AFTER_UPLOAD,,}" in
    true|1|yes)
        UPLOADER_COMMAND+=(--delete-after-upload)
        ;;
    false|0|no)
        ;;
    *)
        echo "DELETE_EVENT_AFTER_UPLOAD must be true or false" >&2
        exit 2
        ;;
esac
"${UPLOADER_COMMAND[@]}" \
    > >(sed -u 's/^/[UPLOAD] /' | tee -a "${RUN_DIR}/uploader.log") 2>&1 &
PIDS+=("$!")

YAMNET_COMMAND=(
    "$YAMNET_PYTHON" -u "${YAMNET_DIR}/yamnet_laughter_detect_jetson.py"
    --device-id "$DEVICE_ID"
    --stream-url "$LOCAL_RTSP_AI_URL"
    --score-aggregation "$YAMNET_SCORE_AGGREGATION"
    --threshold "$YAMNET_THRESHOLD"
    --consecutive "$YAMNET_CONSECUTIVE"
    --cooldown "$YAMNET_COOLDOWN"
    --gain "$YAMNET_GAIN"
    --event-dir "$EVENT_DIR"
    --clip-seconds "$EVENT_CLIP_SECONDS"
    --trigger-only
)
MQTT_HOST= "${YAMNET_COMMAND[@]}" \
    > >(sed -u 's/^/[YAMNET] /' | tee -a "${RUN_DIR}/yamnet.log") 2>&1 &
PIDS+=("$!")

YOLO_COMMAND=(
    "$YOLO_PYTHON" -u "${SCRIPT_DIR}/yolov8_autoframe_jetson.py"
    --stream-url "$LOCAL_RTSP_AI_URL"
    --device-id "$DEVICE_ID"
    --mqtt-host "$LOCAL_MQTT_HOST"
    --mqtt-port "$LOCAL_MQTT_PORT"
    --command-interval 0.10
    --deadzone-width "$YOLO_DEADZONE_WIDTH"
    --deadzone-height "$YOLO_DEADZONE_HEIGHT"
    --control-output "${RUN_DIR}/autoframe_commands.jsonl"
    --dashboard-host "$SERVO_DASHBOARD_HOST"
    --dashboard-port "$SERVO_DASHBOARD_PORT"
    --dashboard-log "${RUN_DIR}/servo_dashboard.jsonl"
    --dashboard-frame-width "$SERVO_DASHBOARD_FRAME_WIDTH"
    --dashboard-jpeg-quality "$SERVO_DASHBOARD_JPEG_QUALITY"
    --dashboard-frame-interval "$SERVO_DASHBOARD_FRAME_INTERVAL_SECONDS"
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
