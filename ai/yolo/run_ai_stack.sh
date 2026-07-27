#!/usr/bin/env bash

# Start YOLO, YAMNet, MQTT event fusion, and resource logging as one stack.
# Each component still runs in its own virtual environment and process.

set -Eeuo pipefail

STACK_HOME="${HOME}"
STACK_USER="${USER:-$(id -un)}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOLO_DIR="${SCRIPT_DIR}"
YAMNET_DIR="${SCRIPT_DIR}/../yamnet"
YOLO_PYTHON="${STACK_HOME}/venvs/yolo/bin/python"
YAMNET_PYTHON="${STACK_HOME}/venvs/yamnet/bin/python"
RUN_ROOT="${STACK_HOME}/ai_runs"

CAMERA_INDEX=0
MIC_DEVICE=""
VIDEO_SOURCE="${VIDEO_SOURCE:-}"
AUDIO_SOURCE="${AUDIO_SOURCE:-}"
DEVICE_ID="${DEVICE_ID:-homecam-001}"
MQTT_HOST="localhost"
MQTT_PORT=1883
LAUGHTER_THRESHOLD=0.20
LAUGHTER_CONSECUTIVE=1
MIC_GAIN=1.5
DURATION_SECONDS=0
RECORD_DEBUG_VIDEO=0
ENABLE_TEGRASTATS=1
LIST_MICS=0

usage() {
    cat <<'EOF'
Usage: ./run_ai_stack.sh [options]

Options:
  --mic-device VALUE       YAMNet input device number or name (default: system input)
  --camera INDEX           V4L2 camera index (default: 0)
  --video-source URI       Shared RTSP/UDP video source; overrides --camera
  --audio-source URI       Shared RTSP/UDP audio source; overrides --mic-device
  --device-id ID           Home camera ID (default: homecam-001)
  --duration SECONDS       Stop cleanly after this duration; 0 runs until Ctrl+C
  --threshold VALUE        YAMNet laughter threshold (default: 0.20)
  --consecutive COUNT      Required consecutive detections (default: 1)
  --gain VALUE             YAMNet microphone gain (default: 1.5)
  --record-debug-video     Save an annotated MP4 in the run directory
  --no-tegrastats          Do not start tegrastats resource logging
  --list-mics              List YAMNet audio devices and exit
  --yolo-dir PATH          YOLO directory (default: this script's directory)
  --yamnet-dir PATH        YAMNet directory (default: ../yamnet)
  --run-root PATH          Parent directory for per-run logs (default: ~/ai_runs)
  --mqtt-host HOST         MQTT broker host (default: localhost)
  --mqtt-port PORT         MQTT broker port (default: 1883)
  -h, --help               Show this help

Examples:
  ./run_ai_stack.sh --mic-device 2 --record-debug-video
  ./run_ai_stack.sh --mic-device "BRIO 100" --duration 600
  ./run_ai_stack.sh \
    --video-source rtsp://127.0.0.1:8554/homecam/ai \
    --audio-source rtsp://127.0.0.1:8554/homecam/ai \
    --device-id homecam-01
EOF
}

require_value() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Missing value for $1" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mic-device)
            require_value "$@"
            MIC_DEVICE="$2"
            shift 2
            ;;
        --camera)
            require_value "$@"
            CAMERA_INDEX="$2"
            shift 2
            ;;
        --video-source)
            require_value "$@"
            VIDEO_SOURCE="$2"
            shift 2
            ;;
        --audio-source)
            require_value "$@"
            AUDIO_SOURCE="$2"
            shift 2
            ;;
        --device-id)
            require_value "$@"
            DEVICE_ID="$2"
            shift 2
            ;;
        --duration)
            require_value "$@"
            DURATION_SECONDS="$2"
            shift 2
            ;;
        --threshold)
            require_value "$@"
            LAUGHTER_THRESHOLD="$2"
            shift 2
            ;;
        --consecutive)
            require_value "$@"
            LAUGHTER_CONSECUTIVE="$2"
            shift 2
            ;;
        --gain)
            require_value "$@"
            MIC_GAIN="$2"
            shift 2
            ;;
        --record-debug-video)
            RECORD_DEBUG_VIDEO=1
            shift
            ;;
        --no-tegrastats)
            ENABLE_TEGRASTATS=0
            shift
            ;;
        --list-mics)
            LIST_MICS=1
            shift
            ;;
        --yolo-dir)
            require_value "$@"
            YOLO_DIR="$2"
            shift 2
            ;;
        --yamnet-dir)
            require_value "$@"
            YAMNET_DIR="$2"
            shift 2
            ;;
        --run-root)
            require_value "$@"
            RUN_ROOT="$2"
            shift 2
            ;;
        --mqtt-host)
            require_value "$@"
            MQTT_HOST="$2"
            shift 2
            ;;
        --mqtt-port)
            require_value "$@"
            MQTT_PORT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! [[ "$CAMERA_INDEX" =~ ^[0-9]+$ ]]; then
    echo "--camera must be a non-negative integer" >&2
    exit 2
fi
if ! [[ "$DURATION_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "--duration must be a non-negative integer" >&2
    exit 2
fi
if ! [[ "$MQTT_PORT" =~ ^[0-9]+$ ]] || (( MQTT_PORT < 1 || MQTT_PORT > 65535 )); then
    echo "--mqtt-port must be between 1 and 65535" >&2
    exit 2
fi
if [[ -z "$DEVICE_ID" ]]; then
    echo "--device-id cannot be empty" >&2
    exit 2
fi

YOLO_SCRIPT="${YOLO_DIR}/yolov8_autoframe_jetson.py"
FUSION_SCRIPT="${YOLO_DIR}/event_fusion_service.py"
YAMNET_SCRIPT="${YAMNET_DIR}/yamnet_laughter_detect_jetson.py"

if (( LIST_MICS == 1 )); then
    if [[ ! -x "$YAMNET_PYTHON" ]]; then
        echo "YAMNet Python not found or not executable: $YAMNET_PYTHON" >&2
        exit 1
    fi
    if [[ ! -e "$YAMNET_SCRIPT" ]]; then
        echo "YAMNet detector not found: $YAMNET_SCRIPT" >&2
        exit 1
    fi
    exec "$YAMNET_PYTHON" -u "$YAMNET_SCRIPT" --list-devices
fi

for required_file in \
    "$YOLO_PYTHON" \
    "$YAMNET_PYTHON" \
    "$YOLO_SCRIPT" \
    "$FUSION_SCRIPT" \
    "${YOLO_DIR}/vision_mqtt_publisher.py" \
    "$YAMNET_SCRIPT"; do
    if [[ ! -e "$required_file" ]]; then
        echo "Required file not found: $required_file" >&2
        exit 1
    fi
done

if [[ "$MQTT_HOST" == "localhost" || "$MQTT_HOST" == "127.0.0.1" ]]; then
    if command -v systemctl >/dev/null 2>&1 \
        && ! systemctl is-active --quiet mosquitto; then
        echo "Mosquitto is not active. Run: sudo systemctl start mosquitto" >&2
        exit 1
    fi
fi
if ! command -v mosquitto_sub >/dev/null 2>&1; then
    echo "mosquitto_sub is missing. Install mosquitto-clients." >&2
    exit 1
fi

"$YOLO_PYTHON" -c \
    "import cv2, torch, ultralytics, lap, paho.mqtt.client" \
    >/dev/null
"$YAMNET_PYTHON" -c \
    "import sounddevice, tensorflow, tensorflow_hub, paho.mqtt.client" \
    >/dev/null

if [[ ! -e "${YAMNET_DIR}/mqtt_event_publisher.py" ]]; then
    echo "Required file not found: ${YAMNET_DIR}/mqtt_event_publisher.py" >&2
    exit 1
fi

LOCK_FILE="/tmp/homecam_ai_stack_${STACK_USER}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another AI stack appears to be running for user ${STACK_USER}." >&2
    exit 1
fi

mkdir -p "$RUN_ROOT"
RUN_ID="$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="${RUN_ROOT}/${RUN_ID}"
mkdir -p "$RUN_DIR"
printf '%s\n' "$RUN_DIR" >"${RUN_ROOT}/latest_run.txt"
if [[ -L "${RUN_ROOT}/latest" || ! -e "${RUN_ROOT}/latest" ]]; then
    ln -sfn "$RUN_ID" "${RUN_ROOT}/latest"
fi

VISION_TOPIC="homecam/v1/${DEVICE_ID}/ai/vision/state"
LAUGHTER_TOPIC="homecam/v1/${DEVICE_ID}/ai/laughter/detected"
FINAL_EVENT_TOPIC="homecam/v1/${DEVICE_ID}/events/memory-candidate"

{
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'started_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'device_id=%s\n' "$DEVICE_ID"
    if [[ -n "$VIDEO_SOURCE" ]]; then
        printf 'video_source_mode=shared-stream\n'
    else
        printf 'video_source_mode=camera\n'
        printf 'camera_index=%s\n' "$CAMERA_INDEX"
    fi
    if [[ -n "$AUDIO_SOURCE" ]]; then
        printf 'audio_source_mode=shared-stream\n'
    else
        printf 'audio_source_mode=microphone\n'
        printf 'mic_device=%s\n' "${MIC_DEVICE:-system-default}"
    fi
    printf 'mqtt_broker=%s:%s\n' "$MQTT_HOST" "$MQTT_PORT"
    printf 'laughter_threshold=%s\n' "$LAUGHTER_THRESHOLD"
    printf 'laughter_consecutive=%s\n' "$LAUGHTER_CONSECUTIVE"
    printf 'mic_gain=%s\n' "$MIC_GAIN"
    printf 'duration_seconds=%s\n' "$DURATION_SECONDS"
    printf 'record_debug_video=%s\n' "$RECORD_DEBUG_VIDEO"
} >"${RUN_DIR}/run_metadata.txt"

declare -a CORE_PIDS=()
declare -a CORE_NAMES=()
declare -a AUX_PIDS=()
CLEANUP_DONE=0
STARTED_PID=""

start_process() {
    local process_name="$1"
    local log_path="$2"
    shift 2
    echo "Starting ${process_name}; log=${log_path}"
    (
        trap - INT TERM
        exec "$@"
    ) >"$log_path" 2>&1 &
    STARTED_PID="$!"
}

stop_pid_gracefully() {
    local process_pid="$1"
    if kill -0 "$process_pid" 2>/dev/null; then
        kill -INT "$process_pid" 2>/dev/null || true
    fi
}

cleanup() {
    local stack_status="$?"
    if (( CLEANUP_DONE == 1 )); then
        return
    fi
    CLEANUP_DONE=1
    set +e
    echo
    echo "Stopping AI stack..."

    for process_pid in "${CORE_PIDS[@]}"; do
        stop_pid_gracefully "$process_pid"
    done

    local deadline=$((SECONDS + 12))
    local any_alive=1
    while (( any_alive == 1 && SECONDS < deadline )); do
        any_alive=0
        for process_pid in "${CORE_PIDS[@]}"; do
            if kill -0 "$process_pid" 2>/dev/null; then
                any_alive=1
                break
            fi
        done
        if (( any_alive == 1 )); then
            sleep 0.2
        fi
    done

    for process_pid in "${CORE_PIDS[@]}"; do
        if kill -0 "$process_pid" 2>/dev/null; then
            kill -TERM "$process_pid" 2>/dev/null || true
        fi
    done
    for process_pid in "${AUX_PIDS[@]}"; do
        if kill -0 "$process_pid" 2>/dev/null; then
            kill -TERM "$process_pid" 2>/dev/null || true
        fi
    done
    for process_pid in "${CORE_PIDS[@]}" "${AUX_PIDS[@]}"; do
        wait "$process_pid" 2>/dev/null || true
    done
    printf 'stopped_at=%s\n' "$(date --iso-8601=seconds)" \
        >>"${RUN_DIR}/run_metadata.txt"
    printf 'exit_status=%s\n' "$stack_status" >>"${RUN_DIR}/run_metadata.txt"
    echo "Stopped. Logs: ${RUN_DIR}"
}

on_signal() {
    exit 130
}

trap on_signal INT TERM
trap cleanup EXIT

start_process \
    "MQTT event subscriber" \
    "${RUN_DIR}/mqtt_events.log" \
    mosquitto_sub \
    -h "$MQTT_HOST" \
    -p "$MQTT_PORT" \
    -t "$FINAL_EVENT_TOPIC" \
    -q 1 \
    -v
AUX_PIDS+=("$STARTED_PID")

if (( ENABLE_TEGRASTATS == 1 )) && command -v tegrastats >/dev/null 2>&1; then
    start_process \
        "tegrastats" \
        "${RUN_DIR}/resources.log" \
        tegrastats --interval 1000
    AUX_PIDS+=("$STARTED_PID")
fi

start_process \
    "event fusion" \
    "${RUN_DIR}/fusion.log" \
    "$YOLO_PYTHON" -u "$FUSION_SCRIPT" \
    --mqtt-host "$MQTT_HOST" \
    --mqtt-port "$MQTT_PORT" \
    --device-id "$DEVICE_ID"
CORE_PIDS+=("$STARTED_PID")
CORE_NAMES+=("event-fusion")

YOLO_COMMAND=(
    "$YOLO_PYTHON" -u "$YOLO_SCRIPT"
    --mqtt-host "$MQTT_HOST"
    --mqtt-port "$MQTT_PORT"
    --device-id "$DEVICE_ID"
    --control-output "${RUN_DIR}/autoframe_commands.jsonl"
)
if [[ -n "$VIDEO_SOURCE" ]]; then
    YOLO_COMMAND+=(--stream-url "$VIDEO_SOURCE")
else
    YOLO_COMMAND+=(--camera "$CAMERA_INDEX")
fi
if (( RECORD_DEBUG_VIDEO == 1 )); then
    YOLO_COMMAND+=(--output "${RUN_DIR}/autoframe.mp4")
fi
start_process "YOLO auto framing" "${RUN_DIR}/yolo.log" "${YOLO_COMMAND[@]}"
CORE_PIDS+=("$STARTED_PID")
CORE_NAMES+=("yolo")

YAMNET_COMMAND=(
    "$YAMNET_PYTHON" -u "$YAMNET_SCRIPT"
    --mqtt-host "$MQTT_HOST"
    --mqtt-port "$MQTT_PORT"
    --device-id "$DEVICE_ID"
    --threshold "$LAUGHTER_THRESHOLD"
    --consecutive "$LAUGHTER_CONSECUTIVE"
    --gain "$MIC_GAIN"
)
if [[ -n "$AUDIO_SOURCE" ]]; then
    YAMNET_COMMAND+=(--stream-url "$AUDIO_SOURCE")
elif [[ -n "$MIC_DEVICE" ]]; then
    YAMNET_COMMAND+=(--device "$MIC_DEVICE")
fi
start_process "YAMNet laughter" "${RUN_DIR}/yamnet.log" "${YAMNET_COMMAND[@]}"
CORE_PIDS+=("$STARTED_PID")
CORE_NAMES+=("yamnet")

echo
echo "AI stack started. Run directory: ${RUN_DIR}"
echo "Final MQTT topic: ${FINAL_EVENT_TOPIC}"
echo "Follow logs from another SSH terminal:"
echo "  tail -F ${RUN_DIR}/yolo.log ${RUN_DIR}/yamnet.log ${RUN_DIR}/fusion.log"
echo "Press Ctrl+C once to stop all components cleanly."

STACK_STARTED_AT=$SECONDS
while true; do
    if (( DURATION_SECONDS > 0 && SECONDS - STACK_STARTED_AT >= DURATION_SECONDS )); then
        echo "Configured duration reached: ${DURATION_SECONDS}s"
        exit 0
    fi

    for index in "${!CORE_PIDS[@]}"; do
        process_pid="${CORE_PIDS[$index]}"
        if ! kill -0 "$process_pid" 2>/dev/null; then
            set +e
            wait "$process_pid"
            process_status="$?"
            set -e
            echo "${CORE_NAMES[$index]} exited unexpectedly with status ${process_status}." >&2
            exit 1
        fi
    done
    sleep 1
done
