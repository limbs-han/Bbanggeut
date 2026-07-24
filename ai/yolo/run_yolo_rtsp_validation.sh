#!/usr/bin/env bash

# Run a bounded, evidence-producing YOLO validation against Jetson's local
# /homecam/ai RTSP source. This script never stops an existing AI service.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOLO_PYTHON="${YOLO_PYTHON:-${HOME}/venvs/yolo/bin/python}"
YOLO_SCRIPT="${SCRIPT_DIR}/yolov8_autoframe_jetson.py"
SUMMARY_SCRIPT="${SCRIPT_DIR}/summarize_yolo_validation.py"
SOURCE_URL="${YOLO_VALIDATION_SOURCE:-rtsp://127.0.0.1:8554/homecam/ai}"
RUN_ROOT="${YOLO_VALIDATION_ROOT:-${HOME}/ai_validation}"
DEVICE_ID="${DEVICE_ID:-validation-device}"
DURATION_SECONDS=120
CONFIDENCE=0.35
IMAGE_SIZE=640
INFERENCE_DEVICE="auto"
TESTED_CLASSES="${YOLO_VALIDATION_TESTED_CLASSES:-person}"
ENABLE_TEGRASTATS=1

usage() {
    cat <<'EOF'
Usage: ./run_yolo_rtsp_validation.sh [options]

Options:
  --duration SECONDS       Wall-clock test duration (default: 120)
  --source RTSP_URL        Loopback RTSP source
  --confidence VALUE       YOLO confidence threshold (default: 0.35)
  --imgsz PIXELS           YOLO inference image size (default: 640)
  --device VALUE           auto, cpu, or CUDA index such as 0 (default: auto)
  --tested-classes LIST    Classes intentionally shown (default: person)
  --run-root PATH          Parent directory for validation evidence
  --no-tegrastats          Do not record Jetson resource data
  -h, --help               Show this help

The script records:
  annotated.mp4
  autoframe_commands.jsonl
  yolo.log
  resources.log (when tegrastats is available)
  summary.json
  summary.md

An already-running yolov8_autoframe_jetson.py process causes a safe refusal.
Stop only the existing AI service before this test; keep media source,
MediaMTX, and continuous recording active.
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
        --duration)
            require_value "$@"
            DURATION_SECONDS="$2"
            shift 2
            ;;
        --source)
            require_value "$@"
            SOURCE_URL="$2"
            shift 2
            ;;
        --confidence)
            require_value "$@"
            CONFIDENCE="$2"
            shift 2
            ;;
        --imgsz)
            require_value "$@"
            IMAGE_SIZE="$2"
            shift 2
            ;;
        --device)
            require_value "$@"
            INFERENCE_DEVICE="$2"
            shift 2
            ;;
        --tested-classes)
            require_value "$@"
            TESTED_CLASSES="$2"
            shift 2
            ;;
        --run-root)
            require_value "$@"
            RUN_ROOT="$2"
            shift 2
            ;;
        --no-tegrastats)
            ENABLE_TEGRASTATS=0
            shift
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

if ! [[ "$DURATION_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "--duration must be a positive integer" >&2
    exit 2
fi
if ! [[ "$IMAGE_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    echo "--imgsz must be a positive integer" >&2
    exit 2
fi
if ! [[ "$CONFIDENCE" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
    echo "--confidence must be a number from 0 to 1" >&2
    exit 2
fi
case "$SOURCE_URL" in
    rtsp://127.0.0.1:*|rtsp://localhost:*)
        ;;
    *)
        echo "Validation source must be a loopback RTSP URL: $SOURCE_URL" >&2
        exit 2
        ;;
esac

for required_file in "$YOLO_PYTHON" "$YOLO_SCRIPT" "$SUMMARY_SCRIPT"; do
    if [[ ! -e "$required_file" ]]; then
        echo "Required file not found: $required_file" >&2
        exit 1
    fi
done
for required_command in ffprobe pgrep tee; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "Required command not found: $required_command" >&2
        exit 1
    fi
done

EXISTING_PROCESSES="$(pgrep -af '[y]olov8_autoframe_jetson.py' || true)"
if [[ -n "$EXISTING_PROCESSES" ]]; then
    echo "An existing YOLO process is running; no process was stopped:" >&2
    printf '%s\n' "$EXISTING_PROCESSES" >&2
    echo "Stop the active AI service, then run this validation again." >&2
    exit 1
fi

for service in wj-media-source wj-mediamtx-local; do
    if command -v systemctl >/dev/null 2>&1 \
        && ! systemctl is-active --quiet "$service"; then
        echo "Required service is not active: $service" >&2
        exit 1
    fi
done

echo "Probing local RTSP video..."
if command -v timeout >/dev/null 2>&1; then
    timeout 15 ffprobe \
        -v error \
        -rtsp_transport tcp \
        -select_streams v:0 \
        -show_entries stream=codec_name,width,height,r_frame_rate \
        -of default=noprint_wrappers=1 \
        "$SOURCE_URL"
else
    ffprobe \
        -v error \
        -rtsp_transport tcp \
        -select_streams v:0 \
        -show_entries stream=codec_name,width,height,r_frame_rate \
        -of default=noprint_wrappers=1 \
        "$SOURCE_URL"
fi

mkdir -p "$RUN_ROOT"
RUN_ID="$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="${RUN_ROOT}/yolo_rtsp_${RUN_ID}"
mkdir -p "$RUN_DIR"

YOLO_LOG="${RUN_DIR}/yolo.log"
COMMANDS_JSONL="${RUN_DIR}/autoframe_commands.jsonl"
ANNOTATED_VIDEO="${RUN_DIR}/annotated.mp4"
RESOURCE_LOG="${RUN_DIR}/resources.log"
METADATA="${RUN_DIR}/metadata.txt"
YOLO_PID=""
TEGRASTATS_PID=""
CLEANUP_DONE=0

cleanup() {
    local status="$?"
    if (( CLEANUP_DONE == 1 )); then
        return
    fi
    CLEANUP_DONE=1
    set +e
    if [[ -n "$YOLO_PID" ]] && kill -0 "$YOLO_PID" 2>/dev/null; then
        kill -INT "$YOLO_PID" 2>/dev/null
        wait "$YOLO_PID" 2>/dev/null
    fi
    if [[ -n "$TEGRASTATS_PID" ]] && kill -0 "$TEGRASTATS_PID" 2>/dev/null; then
        kill -TERM "$TEGRASTATS_PID" 2>/dev/null
        wait "$TEGRASTATS_PID" 2>/dev/null
    fi
    return "$status"
}

on_signal() {
    exit 130
}

trap on_signal INT TERM
trap cleanup EXIT

{
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'started_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'source=loopback-homecam-ai\n'
    printf 'duration_seconds=%s\n' "$DURATION_SECONDS"
    printf 'confidence=%s\n' "$CONFIDENCE"
    printf 'imgsz=%s\n' "$IMAGE_SIZE"
    printf 'inference_device=%s\n' "$INFERENCE_DEVICE"
    printf 'model=%s\n' "${SCRIPT_DIR}/yolov8n.pt"
    printf 'python=%s\n' "$("$YOLO_PYTHON" --version 2>&1)"
} >"$METADATA"

if (( ENABLE_TEGRASTATS == 1 )) && command -v tegrastats >/dev/null 2>&1; then
    tegrastats --interval 1000 >"$RESOURCE_LOG" 2>&1 &
    TEGRASTATS_PID="$!"
fi

YOLO_COMMAND=(
    "$YOLO_PYTHON" -u "$YOLO_SCRIPT"
    --stream-url "$SOURCE_URL"
    --device "$INFERENCE_DEVICE"
    --imgsz "$IMAGE_SIZE"
    --confidence "$CONFIDENCE"
    --device-id "$DEVICE_ID"
    --control-output "$COMMANDS_JSONL"
    --output "$ANNOTATED_VIDEO"
)

echo "Starting YOLO RTSP validation for ${DURATION_SECONDS}s"
echo "Evidence directory: $RUN_DIR"
(
    trap - INT TERM
    exec "${YOLO_COMMAND[@]}"
) > >(tee "$YOLO_LOG") 2>&1 &
YOLO_PID="$!"

completed_early=0
for ((elapsed = 0; elapsed < DURATION_SECONDS; elapsed += 1)); do
    if ! kill -0 "$YOLO_PID" 2>/dev/null; then
        completed_early=1
        break
    fi
    sleep 1
done

if (( completed_early == 0 )) && kill -0 "$YOLO_PID" 2>/dev/null; then
    kill -INT "$YOLO_PID" 2>/dev/null || true
fi

set +e
wait "$YOLO_PID"
YOLO_STATUS="$?"
set -e
YOLO_PID=""

if [[ -n "$TEGRASTATS_PID" ]] && kill -0 "$TEGRASTATS_PID" 2>/dev/null; then
    kill -TERM "$TEGRASTATS_PID" 2>/dev/null || true
    wait "$TEGRASTATS_PID" 2>/dev/null || true
    TEGRASTATS_PID=""
fi

printf 'finished_at=%s\n' "$(date --iso-8601=seconds)" >>"$METADATA"
printf 'yolo_exit_status=%s\n' "$YOLO_STATUS" >>"$METADATA"

if (( YOLO_STATUS != 0 && YOLO_STATUS != 130 )); then
    echo "YOLO exited unexpectedly with status $YOLO_STATUS" >&2
    echo "Inspect: $YOLO_LOG" >&2
    exit "$YOLO_STATUS"
fi
if [[ ! -s "$COMMANDS_JSONL" ]]; then
    echo "No framing command evidence was produced: $COMMANDS_JSONL" >&2
    exit 1
fi

"$YOLO_PYTHON" "$SUMMARY_SCRIPT" \
    --commands "$COMMANDS_JSONL" \
    --log "$YOLO_LOG" \
    --output-dir "$RUN_DIR" \
    --tested-classes "$TESTED_CLASSES"

echo
echo "Validation finished."
echo "Review summary: ${RUN_DIR}/summary.md"
echo "Review video:   ${RUN_DIR}/annotated.mp4"
