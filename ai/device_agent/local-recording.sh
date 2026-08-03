#!/usr/bin/env bash

# Save the compressed main stream as restart-safe one-minute MPEG-TS segments.
# No video or audio is re-encoded.

set -Eeuo pipefail

: "${FFMPEG_PATH:=/usr/bin/ffmpeg}"
: "${LOCAL_RTSP_MAIN_URL:=rtsp://127.0.0.1:8554/homecam/main}"
: "${RECORDING_DIR:=/var/lib/william-james/recordings}"
: "${RECORDING_SEGMENT_SECONDS:=60}"
: "${RECORDING_TIMEZONE:=Asia/Seoul}"

if [[ "$RECORDING_DIR" != /* || "$RECORDING_DIR" == "/" ]]; then
    echo "RECORDING_DIR must be a specific absolute directory" >&2
    exit 2
fi
if ! [[ "$RECORDING_SEGMENT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "RECORDING_SEGMENT_SECONDS must be a positive integer" >&2
    exit 2
fi
if [[ ! -f "${RECORDING_DIR}/.homecam-recordings" ]]; then
    echo "Recording safety marker is missing: ${RECORDING_DIR}/.homecam-recordings" >&2
    exit 1
fi
if [[ ! -w "$RECORDING_DIR" ]]; then
    echo "Recording directory is not writable: ${RECORDING_DIR}" >&2
    exit 1
fi

umask 0027
export TZ="$RECORDING_TIMEZONE"
exec "$FFMPEG_PATH" \
    -hide_banner -nostdin -loglevel warning \
    -rtsp_transport tcp \
    -i "$LOCAL_RTSP_MAIN_URL" \
    -map 0:v:0 -map 0:a:0 \
    -c copy \
    -f segment \
    -segment_format mpegts \
    -segment_time "$RECORDING_SEGMENT_SECONDS" \
    -reset_timestamps 1 \
    -strftime 1 \
    "${RECORDING_DIR}/homecam-%Y%m%dT%H%M%S.ts"
