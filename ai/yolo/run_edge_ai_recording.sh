#!/usr/bin/env bash

# Disk-backed Jetson AI stack:
# - YOLO and YAMNet consume the validated shared RTSP path.
# - YAMNet writes lightweight trigger JSON only.
# - The uploader merges repeated event types within 30 seconds, and merges
#   laughter with clapping within 5 seconds. It extracts the first detection
#   -60 seconds through the last detection +60 seconds from rolling MPEG-TS.
#
# Keep run_edge_ai_mvp.sh available as the 5-second UDP fallback.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YAMNET_DIR="${YAMNET_DIR:-${SCRIPT_DIR}/../yamnet}"
YOLO_PYTHON="${YOLO_PYTHON:-${HOME}/venvs/yolo/bin/python}"
YAMNET_PYTHON="${YAMNET_PYTHON:-${HOME}/venvs/yamnet/bin/python}"
WAKE_NAME_PYTHON="${WAKE_NAME_PYTHON:-${HOME}/venvs/wake-name/bin/python}"
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
: "${RECORDING_TIMEZONE:=Asia/Seoul}"
: "${EVENT_CLIP_SECONDS:=60}"
: "${EVENT_MERGE_GAP_SECONDS:=30}"
: "${EVENT_CROSS_TYPE_MERGE_GAP_SECONDS:=5}"
: "${DELETE_EVENT_AFTER_UPLOAD:=true}"
: "${LOCAL_MQTT_HOST:=127.0.0.1}"
: "${LOCAL_MQTT_PORT:=1883}"
: "${YOLO_DEADZONE_WIDTH:=0.08}"
: "${YOLO_DEADZONE_HEIGHT:=0.06}"
: "${YOLO_SUBJECT_Y_RATIO:=0.35}"
: "${YOLO_RUNTIME:=auto}"
: "${YOLO_TENSORRT_ENGINE_PATH:=${HOME}/ai_models/yolo-detect-engine/yolov8n-fp16-b1-640.engine}"
: "${YOLO_TENSORRT_ENGINE_SHA256:=}"
: "${YOLO_PYTORCH_MODEL_PATH:=${SCRIPT_DIR}/yolov8n.pt}"
: "${YOLO_TENSORRT_PROBE:=true}"
: "${YOLO_TENSORRT_PROBE_DEVICE:=0}"
: "${SERVO_DASHBOARD_HOST:=127.0.0.1}"
: "${SERVO_DASHBOARD_PORT:=8765}"
: "${SERVO_DASHBOARD_FRAME_WIDTH:=960}"
: "${SERVO_DASHBOARD_JPEG_QUALITY:=72}"
: "${SERVO_DASHBOARD_FRAME_INTERVAL_SECONDS:=0.2}"
: "${YAMNET_SCORE_AGGREGATION:=mean}"
: "${YAMNET_THRESHOLD:=0.125}"
: "${YAMNET_CONSECUTIVE:=3}"
: "${YAMNET_COOLDOWN:=12}"
: "${YAMNET_GAIN:=1.5}"
: "${YAMNET_READY_TIMEOUT_SECONDS:=90}"
: "${YAMNET_RESTART_DELAY_SECONDS:=5}"
: "${YAMNET_CLAP_ENABLED:=false}"
: "${YAMNET_CLAP_THRESHOLD:=0.30}"
: "${YAMNET_CLAP_CONSECUTIVE:=2}"
: "${YAMNET_CLAP_REQUIRED_ONSETS:=3}"
: "${YAMNET_CLAP_MIN_ACTIVE_SECONDS:=0.4}"
: "${YAMNET_CLAP_MAX_GAP_SECONDS:=0.75}"
: "${YAMNET_CLAP_COOLDOWN:=12}"
: "${WAKE_NAME_ENABLED:=false}"
: "${WAKE_NAME_PROFILE_DIR:=${HOME}/.local/share/william-james/wake-name}"
: "${WAKE_NAME_MODEL_DIR:=${HOME}/ai_models/faster-whisper-small}"
: "${WAKE_NAME_THRESHOLD:=0.82}"
: "${WAKE_NAME_COOLDOWN:=12}"
: "${WAKE_NAME_ASR_DEVICE:=cpu}"
: "${WAKE_NAME_ASR_COMPUTE_TYPE:=int8}"
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
if [[ ! "$YAMNET_READY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "YAMNET_READY_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
fi
if [[ ! "$YAMNET_RESTART_DELAY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "YAMNET_RESTART_DELAY_SECONDS must be a positive integer" >&2
    exit 2
fi

for required in \
    "$YOLO_PYTHON" \
    "$YAMNET_PYTHON" \
    "${SCRIPT_DIR}/yolov8_autoframe_jetson.py" \
    "${SCRIPT_DIR}/yolo_runtime_selector.py" \
    "$YOLO_PYTORCH_MODEL_PATH" \
    "${SCRIPT_DIR}/segment_clip_uploader.py" \
    "${YAMNET_DIR}/yamnet_laughter_detect_jetson.py" \
    "${YAMNET_DIR}/local_wake_name_detect_jetson.py" \
    "${RECORDING_DIR}/.homecam-recordings"; do
    if [[ ! -e "$required" ]]; then
        echo "Required file not found: $required" >&2
        exit 1
    fi
done

case "${WAKE_NAME_ENABLED,,}" in
    true|1|yes)
        for required in \
            "$WAKE_NAME_PYTHON" \
            "${WAKE_NAME_PROFILE_DIR}/profile.json" \
            "$WAKE_NAME_MODEL_DIR"; do
            if [[ ! -e "$required" ]]; then
                echo "Wake-name requirement not found: $required" >&2
                exit 1
            fi
        done
        ;;
    false|0|no)
        ;;
    *)
        echo "WAKE_NAME_ENABLED must be true or false" >&2
        exit 2
        ;;
esac

mkdir -p "$EVENT_DIR"
RUN_DIR="${EVENT_DIR}/logs/$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$RUN_DIR"
YAMNET_DIAGNOSTICS_PATH="${RUN_DIR}/yamnet_diagnostics.jsonl"
YOLO_SELECTION_FILE="${RUN_DIR}/yolo_runtime_selection.tsv"

YOLO_SELECTOR_COMMAND=(
    "$YOLO_PYTHON" "${SCRIPT_DIR}/yolo_runtime_selector.py"
    --runtime "$YOLO_RUNTIME"
    --engine-path "$YOLO_TENSORRT_ENGINE_PATH"
    --pytorch-path "$YOLO_PYTORCH_MODEL_PATH"
    --engine-sha256 "$YOLO_TENSORRT_ENGINE_SHA256"
    --probe-device "$YOLO_TENSORRT_PROBE_DEVICE"
    --result-file "$YOLO_SELECTION_FILE"
)
case "${YOLO_TENSORRT_PROBE,,}" in
    true|1|yes)
        ;;
    false|0|no)
        YOLO_SELECTOR_COMMAND+=(--skip-engine-probe)
        ;;
    *)
        echo "YOLO_TENSORRT_PROBE must be true or false" >&2
        exit 2
        ;;
esac

if ! "${YOLO_SELECTOR_COMMAND[@]}"; then
    if [[ "${YOLO_RUNTIME,,}" != "auto" ]]; then
        echo "Strict YOLO runtime selection failed" >&2
        exit 1
    fi
    echo \
        "YOLO runtime selector exited unexpectedly; forcing PyTorch fallback" \
        >&2
    rm -f -- "$YOLO_SELECTION_FILE"
    "$YOLO_PYTHON" "${SCRIPT_DIR}/yolo_runtime_selector.py" \
        --runtime pytorch \
        --engine-path "$YOLO_TENSORRT_ENGINE_PATH" \
        --pytorch-path "$YOLO_PYTORCH_MODEL_PATH" \
        --skip-engine-probe \
        --result-file "$YOLO_SELECTION_FILE"
fi
IFS=$'\t' read -r YOLO_SELECTED_RUNTIME YOLO_SELECTED_MODEL \
    < "$YOLO_SELECTION_FILE"
if [[ -z "$YOLO_SELECTED_RUNTIME" || -z "$YOLO_SELECTED_MODEL" ]]; then
    echo "YOLO runtime selector returned an invalid result" >&2
    exit 1
fi

declare -a PIDS=()
YAMNET_PID=""
YAMNET_RESTART_AT=0

child_is_running() {
    local pid="$1"
    local state
    state="$(ps -o stat= -p "$pid" 2>/dev/null)" || return 1
    [[ -n "$state" && "${state:0:1}" != "Z" ]]
}

remove_managed_pid() {
    local removed_pid="$1"
    local pid
    local -a remaining=()
    for pid in "${PIDS[@]}"; do
        if [[ "$pid" != "$removed_pid" ]]; then
            remaining+=("$pid")
        fi
    done
    PIDS=("${remaining[@]}")
}

wait_for_children_to_stop() {
    local attempts="$1"
    local attempt
    local pid
    local any_running
    for ((attempt = 0; attempt < attempts; attempt += 1)); do
        any_running=false
        for pid in "${PIDS[@]}"; do
            if child_is_running "$pid"; then
                any_running=true
                break
            fi
        done
        if [[ "$any_running" == false ]]; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

cleanup() {
    local status="$?"
    local pid
    trap - EXIT INT TERM
    if ((${#PIDS[@]} > 0)); then
        for pid in "${PIDS[@]}"; do
            kill -INT "$pid" 2>/dev/null || true
        done
        if ! wait_for_children_to_stop 20; then
            echo "Escalating AI child shutdown to SIGTERM" >&2
            for pid in "${PIDS[@]}"; do
                kill -TERM "$pid" 2>/dev/null || true
            done
            if ! wait_for_children_to_stop 8; then
                echo "Escalating AI child shutdown to SIGKILL" >&2
                for pid in "${PIDS[@]}"; do
                    kill -KILL "$pid" 2>/dev/null || true
                done
            fi
        fi
        for pid in "${PIDS[@]}"; do
            if ! child_is_running "$pid"; then
                wait "$pid" 2>/dev/null || true
            fi
        done
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

echo "Starting disk-backed edge AI for device ${DEVICE_ID}"
echo "AI source: loopback RTSP"
echo "Rolling recordings: ${RECORDING_DIR}"
echo "Event clips: ${EVENT_DIR}"
echo \
    "YOLO runtime: requested=${YOLO_RUNTIME} " \
    "selected=${YOLO_SELECTED_RUNTIME} model=${YOLO_SELECTED_MODEL}"
echo \
    "YAMNet detector: aggregation=${YAMNET_SCORE_AGGREGATION} " \
    "threshold=${YAMNET_THRESHOLD} consecutive=${YAMNET_CONSECUTIVE} " \
    "cooldown=${YAMNET_COOLDOWN}s gain=${YAMNET_GAIN}"
echo \
    "Clap detector: enabled=${YAMNET_CLAP_ENABLED} " \
    "threshold=${YAMNET_CLAP_THRESHOLD} " \
    "consecutive=${YAMNET_CLAP_CONSECUTIVE} " \
    "onsets=${YAMNET_CLAP_REQUIRED_ONSETS} " \
    "minimumActive=${YAMNET_CLAP_MIN_ACTIVE_SECONDS}s"
echo \
    "Wake-name detector: enabled=${WAKE_NAME_ENABLED} " \
    "threshold=${WAKE_NAME_THRESHOLD} cooldown=${WAKE_NAME_COOLDOWN}s"
echo \
    "Upload retry: initial=${UPLOAD_RETRY_INITIAL_SECONDS}s " \
    "maximum=${UPLOAD_RETRY_MAX_SECONDS}s; terminal 4xx is quarantined"

YAMNET_COMMAND=(
    "$YAMNET_PYTHON" -u "${YAMNET_DIR}/yamnet_laughter_detect_jetson.py"
    --device-id "$DEVICE_ID"
    --mqtt-host "$LOCAL_MQTT_HOST"
    --mqtt-port "$LOCAL_MQTT_PORT"
    --stream-url "$LOCAL_RTSP_AI_URL"
    --score-aggregation "$YAMNET_SCORE_AGGREGATION"
    --threshold "$YAMNET_THRESHOLD"
    --consecutive "$YAMNET_CONSECUTIVE"
    --cooldown "$YAMNET_COOLDOWN"
    --gain "$YAMNET_GAIN"
    --diagnostics-jsonl "$YAMNET_DIAGNOSTICS_PATH"
    --event-dir "$EVENT_DIR"
    --clip-seconds "$EVENT_CLIP_SECONDS"
    --trigger-only
)
case "${YAMNET_CLAP_ENABLED,,}" in
    true|1|yes)
        YAMNET_COMMAND+=(
            --enable-clap-events
            --clap-threshold "$YAMNET_CLAP_THRESHOLD"
            --clap-consecutive "$YAMNET_CLAP_CONSECUTIVE"
            --clap-required-onsets "$YAMNET_CLAP_REQUIRED_ONSETS"
            --clap-min-active-seconds "$YAMNET_CLAP_MIN_ACTIVE_SECONDS"
            --clap-max-gap-seconds "$YAMNET_CLAP_MAX_GAP_SECONDS"
            --clap-cooldown "$YAMNET_CLAP_COOLDOWN"
        )
        ;;
    false|0|no)
        ;;
    *)
        echo "YAMNET_CLAP_ENABLED must be true or false" >&2
        exit 2
        ;;
esac

write_yamnet_status() {
    local status="$1"
    local detail="$2"
    local observed_at
    observed_at="$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')"
    printf \
        '{"observedAt":"%s","status":"%s","detail":"%s"}\n' \
        "$observed_at" "$status" "$detail" \
        >> "$YAMNET_DIAGNOSTICS_PATH"
}

yamnet_has_inference() {
    grep -q '"selectedScore"' "$YAMNET_DIAGNOSTICS_PATH" 2>/dev/null
}

start_yamnet() {
    "${YAMNET_COMMAND[@]}" \
        > >(sed -u 's/^/[YAMNET] /' |
            tee -a "${RUN_DIR}/yamnet.log") 2>&1 &
    YAMNET_PID="$!"
    PIDS+=("$YAMNET_PID")
}

write_yamnet_status "STARTING" "Waiting for first inference"
start_yamnet

echo \
    "Waiting up to ${YAMNET_READY_TIMEOUT_SECONDS}s for YAMNet first inference"
# Use a wall-clock deadline (date +%s) rather than bash's $SECONDS. $SECONDS
# is relative to when *this shell* started, which is normally fine, but it is
# an easy thing to get wrong (e.g. it does not survive `exec`, and it is easy
# to accidentally read it from a different shell/subshell than the one that
# set the baseline). A plain epoch-seconds comparison has no such surprises
# and matches what an operator sees in `date`/journal timestamps.
yamnet_wait_started="$(date +%s)"
yamnet_ready_deadline=$((yamnet_wait_started + YAMNET_READY_TIMEOUT_SECONDS))
yamnet_initial_ready=false
while ! yamnet_has_inference; do
    if ! child_is_running "$YAMNET_PID"; then
        if wait "$YAMNET_PID"; then
            yamnet_status=0
        else
            yamnet_status="$?"
        fi
        remove_managed_pid "$YAMNET_PID"
        YAMNET_PID=""
        YAMNET_RESTART_AT=$((
            $(date +%s) + YAMNET_RESTART_DELAY_SECONDS
        ))
        echo \
            "YAMNet exited before readiness (status=${yamnet_status})." \
            "Continuing in degraded mode; YAMNet will restart independently." \
            "Last log lines:" \
            >&2
        tail -n 20 "${RUN_DIR}/yamnet.log" >&2 2>/dev/null || true
        write_yamnet_status \
            "UNAVAILABLE" \
            "Exited before readiness; restart scheduled"
        break
    fi
    now="$(date +%s)"
    if (( now >= yamnet_ready_deadline )); then
        if yamnet_has_inference; then
            yamnet_initial_ready=true
            break
        fi
        echo \
            "YAMNet readiness timed out after " \
            "$((now - yamnet_wait_started))s " \
            "(limit ${YAMNET_READY_TIMEOUT_SECONDS}s). " \
            "Continuing in degraded mode while YAMNet keeps running. " \
            "Last log lines:" \
            >&2
        tail -n 20 "${RUN_DIR}/yamnet.log" >&2 2>/dev/null || true
        write_yamnet_status \
            "UNAVAILABLE" \
            "Readiness timed out; detector still running"
        break
    fi
    sleep 0.25
done
if yamnet_has_inference; then
    yamnet_initial_ready=true
fi
if [[ "$yamnet_initial_ready" == true ]]; then
    echo \
        "YAMNet ready: first inference telemetry received after " \
        "$(( $(date +%s) - yamnet_wait_started ))s"
else
    echo \
        "YAMNet is not ready; starting the remaining AI stack in degraded mode"
fi

# Give YAMNet a bounded head start to reduce TensorFlow/PyTorch startup
# contention. Readiness is observational, not fatal: uploader, wake-name,
# YOLO, and the dashboard still start if YAMNet is slow or temporarily down.
UPLOADER_COMMAND=(
    "$YOLO_PYTHON" -u "${SCRIPT_DIR}/segment_clip_uploader.py"
    --event-dir "$EVENT_DIR"
    --recording-dir "$RECORDING_DIR"
    --api-base-url "$API_BASE_URL"
    --merge-gap-seconds "$EVENT_MERGE_GAP_SECONDS"
    --cross-type-merge-gap-seconds "$EVENT_CROSS_TYPE_MERGE_GAP_SECONDS"
    --segment-seconds "$RECORDING_SEGMENT_SECONDS"
    --recording-timezone "$RECORDING_TIMEZONE"
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

case "${WAKE_NAME_ENABLED,,}" in
    true|1|yes)
        "$WAKE_NAME_PYTHON" -u \
            "${YAMNET_DIR}/local_wake_name_detect_jetson.py" \
            --profile-dir "$WAKE_NAME_PROFILE_DIR" \
            --model-dir "$WAKE_NAME_MODEL_DIR" \
            --stream-url "$LOCAL_RTSP_AI_URL" \
            --event-dir "$EVENT_DIR" \
            --device-id "$DEVICE_ID" \
            --threshold "$WAKE_NAME_THRESHOLD" \
            --cooldown "$WAKE_NAME_COOLDOWN" \
            --clip-seconds "$EVENT_CLIP_SECONDS" \
            --device "$WAKE_NAME_ASR_DEVICE" \
            --compute-type "$WAKE_NAME_ASR_COMPUTE_TYPE" \
            --mqtt-host "$LOCAL_MQTT_HOST" \
            --mqtt-port "$LOCAL_MQTT_PORT" \
            > >(sed -u 's/^/[WAKE_NAME] /' |
                tee -a "${RUN_DIR}/wake_name.log") 2>&1 &
        PIDS+=("$!")
        ;;
esac

YOLO_COMMAND=(
    "$YOLO_PYTHON" -u "${SCRIPT_DIR}/yolov8_autoframe_jetson.py"
    --model "$YOLO_SELECTED_MODEL"
    --stream-url "$LOCAL_RTSP_AI_URL"
    --device-id "$DEVICE_ID"
    --mqtt-host "$LOCAL_MQTT_HOST"
    --mqtt-port "$LOCAL_MQTT_PORT"
    --command-interval 0.10
    --deadzone-width "$YOLO_DEADZONE_WIDTH"
    --deadzone-height "$YOLO_DEADZONE_HEIGHT"
    --subject-y-ratio "$YOLO_SUBJECT_Y_RATIO"
    --control-output "${RUN_DIR}/autoframe_commands.jsonl"
    --dashboard-host "$SERVO_DASHBOARD_HOST"
    --dashboard-port "$SERVO_DASHBOARD_PORT"
    --dashboard-log "${RUN_DIR}/servo_dashboard.jsonl"
    --dashboard-event-dir "$EVENT_DIR"
    --dashboard-yamnet-diagnostics "$YAMNET_DIAGNOSTICS_PATH"
    --dashboard-frame-width "$SERVO_DASHBOARD_FRAME_WIDTH"
    --dashboard-jpeg-quality "$SERVO_DASHBOARD_JPEG_QUALITY"
    --dashboard-frame-interval "$SERVO_DASHBOARD_FRAME_INTERVAL_SECONDS"
)
MQTT_HOST= "${YOLO_COMMAND[@]}" \
    > >(sed -u 's/^/[YOLO] /' | tee -a "${RUN_DIR}/yolo.log") 2>&1 &
PIDS+=("$!")

while true; do
    now="$(date +%s)"
    if [[ -n "$YAMNET_PID" ]] &&
        ! child_is_running "$YAMNET_PID"; then
        if wait "$YAMNET_PID"; then
            yamnet_status=0
        else
            yamnet_status="$?"
        fi
        remove_managed_pid "$YAMNET_PID"
        YAMNET_PID=""
        YAMNET_RESTART_AT=$((now + YAMNET_RESTART_DELAY_SECONDS))
        echo \
            "YAMNet exited (status=${yamnet_status}); restarting only YAMNet " \
            "in ${YAMNET_RESTART_DELAY_SECONDS}s" \
            >&2
        write_yamnet_status \
            "UNAVAILABLE" \
            "Detector exited; restart scheduled"
    fi
    if [[ -z "$YAMNET_PID" ]] && (( now >= YAMNET_RESTART_AT )); then
        echo "Restarting YAMNet detector" >&2
        write_yamnet_status "RESTARTING" "Launching detector"
        start_yamnet
    fi
    for pid in "${PIDS[@]}"; do
        if [[ "$pid" == "$YAMNET_PID" ]]; then
            continue
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"
            exit $?
        fi
    done
    sleep 1
done
