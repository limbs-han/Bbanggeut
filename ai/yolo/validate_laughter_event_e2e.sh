#!/usr/bin/env bash
set -Eeuo pipefail

EVENT_DIR="${EVENT_DIR:-${HOME}/ai_events}"
EDGE_AI_SERVICE="${EDGE_AI_SERVICE:-wj-edge-ai-recording}"
DETECTION_TIMEOUT_SECONDS=90
UPLOAD_TIMEOUT_SECONDS=210
POLL_SECONDS=1

usage() {
    cat <<'EOF'
Usage: ./validate_laughter_event_e2e.sh [options]

Options:
  --event-dir PATH              Event artifact directory
  --detection-timeout SECONDS   Time allowed for laughter detection (default: 90)
  --upload-timeout SECONDS      Time allowed for clip upload (default: 210)
  --poll-seconds SECONDS        Poll interval (default: 1)
  -h, --help                    Show this help

The script observes a newly created trigger file instead of tailing a log.
This prevents a fast laughter event from being missed between the prompt and
the log-following process startup.

Exit codes:
  0  Detected and uploaded (or merged into an uploaded event)
  2  Laughter was not detected
  3  Upload was blocked by a terminal response
  4  Edge AI service stopped during validation
  5  Upload did not finish before the timeout
EOF
}

positive_integer() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "$name must be a positive integer" >&2
        exit 64
    fi
}

while (($# > 0)); do
    case "$1" in
        --event-dir)
            EVENT_DIR="${2:?--event-dir requires a value}"
            shift 2
            ;;
        --detection-timeout)
            DETECTION_TIMEOUT_SECONDS="${2:?--detection-timeout requires a value}"
            shift 2
            ;;
        --upload-timeout)
            UPLOAD_TIMEOUT_SECONDS="${2:?--upload-timeout requires a value}"
            shift 2
            ;;
        --poll-seconds)
            POLL_SECONDS="${2:?--poll-seconds requires a value}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

positive_integer "detection timeout" "$DETECTION_TIMEOUT_SECONDS"
positive_integer "upload timeout" "$UPLOAD_TIMEOUT_SECONDS"
positive_integer "poll interval" "$POLL_SECONDS"

for command in find grep python3 systemctl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command is unavailable: $command" >&2
        exit 69
    fi
done

if [[ ! -d "$EVENT_DIR" ]]; then
    echo "Event directory does not exist: $EVENT_DIR" >&2
    exit 66
fi

if ! systemctl is-active --quiet "$EDGE_AI_SERVICE"; then
    echo "Edge AI service is not active: $EDGE_AI_SERVICE" >&2
    exit 4
fi

latest_run_dir="$(
    find "${EVENT_DIR}/logs" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%T@ %p\n' 2>/dev/null |
        sort -n |
        tail -n 1 |
        cut -d' ' -f2-
)"

if [[ -z "$latest_run_dir" ]]; then
    echo "No edge AI run directory exists under ${EVENT_DIR}/logs" >&2
    exit 66
fi

yamnet_log="${latest_run_dir}/yamnet.log"
uploader_log="${latest_run_dir}/uploader.log"

if [[ ! -f "$yamnet_log" ]] ||
   ! grep -a -q "Audio stream connected" "$yamnet_log"; then
    echo "YAMNet audio connection was not observed: $yamnet_log" >&2
    exit 69
fi

marker="$(mktemp "${EVENT_DIR}/.laughter-e2e-marker.XXXXXX")"
cleanup() {
    rm -f -- "$marker"
}
trap cleanup EXIT

echo "RUN_DIR=$latest_run_dir"
echo "PASS: edge AI and YAMNet audio are ready"
echo
echo "Laugh naturally and clearly for 6 to 8 seconds now."

trigger=""
detection_deadline=$((SECONDS + DETECTION_TIMEOUT_SECONDS))

while ((SECONDS < detection_deadline)); do
    trigger="$(
        find "$EVENT_DIR" \
            -maxdepth 1 \
            -type f \
            -name '*.trigger.json' \
            -newer "$marker" \
            -printf '%T@ %p\n' |
            sort -n |
            head -n 1 |
            cut -d' ' -f2-
    )"

    if [[ -n "$trigger" ]]; then
        break
    fi

    sleep "$POLL_SECONDS"
done

if [[ -z "$trigger" ]]; then
    echo "RESULT=NOT_DETECTED"
    echo "Recent YAMNet scores:"
    tr '\r' '\n' <"$yamnet_log" |
        grep -aE '현재 소리:|웃음 감지!|Local laughter event' |
        tail -n 30 || true
    exit 2
fi

event_id="$(basename "$trigger" .trigger.json)"
if [[ ! "$event_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "Trigger filename does not contain a UUID: $trigger" >&2
    exit 65
fi

echo "RESULT=DETECTED"
echo "EVENT_ID=$event_id"
python3 - "$trigger" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    payload = json.load(file)

for key in (
    "occurredAt",
    "confidence",
    "className",
    "preSeconds",
    "postSeconds",
):
    print(f"{key}={payload.get(key)}")
PY

echo "Waiting for post-event recording coverage and upload."
upload_result="TIMEOUT"
canonical_event_id="$event_id"
upload_deadline=$((SECONDS + UPLOAD_TIMEOUT_SECONDS))

while ((SECONDS < upload_deadline)); do
    if [[ -s "${EVENT_DIR}/${event_id}.uploaded.json" ]]; then
        upload_result="UPLOADED"
        break
    fi

    if [[ -s "${EVENT_DIR}/${event_id}.merged.json" ]]; then
        upload_result="MERGED"
        canonical_event_id="$(
            python3 - "${EVENT_DIR}/${event_id}.merged.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    print(json.load(file)["canonicalEventId"])
PY
        )"
        break
    fi

    if [[ -s "${EVENT_DIR}/${event_id}.upload-blocked.json" ]]; then
        upload_result="BLOCKED"
        break
    fi

    if ! systemctl is-active --quiet "$EDGE_AI_SERVICE"; then
        upload_result="SERVICE_FAILED"
        break
    fi

    sleep "$POLL_SECONDS"
done

echo "UPLOAD_RESULT=$upload_result"
echo "EVENT_ID=$event_id"
echo "CANONICAL_EVENT_ID=$canonical_event_id"

find "$EVENT_DIR" \
    -maxdepth 1 \
    -type f \
    \( -name "${event_id}.*" -o -name "${canonical_event_id}.*" \) \
    -printf '%s %f\n' |
    sort -u

if [[ -f "$uploader_log" ]]; then
    grep -aE "${event_id}|${canonical_event_id}" "$uploader_log" |
        tail -n 30 || true
fi

case "$upload_result" in
    UPLOADED)
        python3 -m json.tool "${EVENT_DIR}/${event_id}.uploaded.json"
        exit 0
        ;;
    MERGED)
        python3 -m json.tool "${EVENT_DIR}/${event_id}.merged.json"
        exit 0
        ;;
    BLOCKED)
        python3 -m json.tool "${EVENT_DIR}/${event_id}.upload-blocked.json"
        exit 3
        ;;
    SERVICE_FAILED)
        echo "Edge AI service stopped before upload completion" >&2
        exit 4
        ;;
    *)
        echo "Upload did not finish before the timeout" >&2
        exit 5
        ;;
esac
