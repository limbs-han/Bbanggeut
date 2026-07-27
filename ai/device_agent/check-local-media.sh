#!/usr/bin/env bash

set -Eeuo pipefail

: "${FFPROBE_PATH:=/usr/bin/ffprobe}"
: "${LOCAL_RTSP_MAIN_URL:=rtsp://127.0.0.1:8554/homecam/main}"
: "${LOCAL_RTSP_AI_URL:=rtsp://127.0.0.1:8554/homecam/ai}"
: "${RECORDING_DIR:=/var/lib/william-james/recordings}"

# The service account can run this command from a caller-owned directory that
# it cannot traverse. Use a neutral working directory before invoking find.
cd /

failures=0

check_stream() {
    local name="$1"
    local source="$2"
    if timeout 12 "$FFPROBE_PATH" \
        -v error \
        -rtsp_transport tcp \
        -show_entries stream=index,codec_type,codec_name \
        -of compact=p=0:nk=1 \
        "$source"; then
        echo "PASS: ${name}"
    else
        echo "FAIL: ${name}" >&2
        failures=$((failures + 1))
    fi
}

check_stream "local RTSP main" "$LOCAL_RTSP_MAIN_URL"
check_stream "local RTSP ai" "$LOCAL_RTSP_AI_URL"

if [[ -d "$RECORDING_DIR" ]]; then
    newest_segment="$(
        find "$RECORDING_DIR" -maxdepth 1 -type f -name 'homecam-*.ts' \
            -printf '%T@ %p\n' |
            sort -nr |
            sed -n '1{s/^[^ ]* //;p;}'
    )"
    if [[ -n "$newest_segment" ]]; then
        echo "PASS: recording segment exists: ${newest_segment}"
    else
        echo "WARN: no completed recording segment exists yet" >&2
    fi
    du -sh "$RECORDING_DIR"
    df -h "$RECORDING_DIR"
else
    echo "WARN: recording directory does not exist: ${RECORDING_DIR}" >&2
fi

if (( failures > 0 )); then
    exit 1
fi
