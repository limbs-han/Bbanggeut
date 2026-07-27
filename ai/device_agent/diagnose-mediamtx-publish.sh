#!/usr/bin/env bash

set -Eeuo pipefail

ENV_FILE="${1:-/etc/william-james/device-agent.env}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -r "$ENV_FILE" ]]; then
    echo "Environment file is not readable: ${ENV_FILE}" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

"$SCRIPT_DIR/verify-mediamtx-rtsps.sh" "$ENV_FILE" >/dev/null

FFMPEG_PATH="${FFMPEG_PATH:-/usr/bin/ffmpeg}"
FFPROBE_PATH="${FFPROBE_PATH:-$(dirname "$FFMPEG_PATH")/ffprobe}"
if [[ ! -x "$FFMPEG_PATH" || ! -x "$FFPROBE_PATH" ]]; then
    echo "FFmpeg and FFprobe are required for the MediaMTX publish diagnostic." >&2
    exit 1
fi

diagnostic_dir="$(mktemp -d)"
chmod 0700 "$diagnostic_dir"
publisher_pid=
cleanup() {
    if [[ -n "$publisher_pid" ]] && kill -0 "$publisher_pid" 2>/dev/null; then
        kill "$publisher_pid" 2>/dev/null || true
        wait "$publisher_pid" 2>/dev/null || true
    fi
    rm -rf -- "$diagnostic_dir"
}
trap cleanup EXIT

stream_id="$(cat /proc/sys/kernel/random/uuid)"
canonical_url="${MEDIA_PUBLISH_URL_TEMPLATE/\{stream_id\}/$stream_id}"
denied_url="${MEDIA_PUBLISH_URL_TEMPLATE/\{stream_id\}/not-a-uuid}"

publish_sample() {
    local destination="$1"
    local duration="$2"
    local log_file="$3"
    timeout "$((duration + 8))" "$FFMPEG_PATH" \
        -hide_banner -nostdin -loglevel error \
        -f lavfi -i "color=c=black:s=160x90:r=5" \
        -t "$duration" -an \
        -c:v libx264 -preset ultrafast -tune zerolatency -g 5 \
        -tls_verify 1 -ca_file "$MEDIA_TLS_CA_CERT" \
        -f rtsp -rtsp_transport tcp "$destination" \
        </dev/null >"$log_file" 2>&1
}

publish_sample "$canonical_url" 6 "$diagnostic_dir/publish.log" &
publisher_pid=$!
sleep 2
if ! kill -0 "$publisher_pid" 2>/dev/null; then
    wait "$publisher_pid" || true
    echo "Authenticated canonical RTSPS publish failed." >&2
    exit 1
fi

if timeout 4 "$FFPROBE_PATH" \
    -v error -rtsp_transport tcp \
    -tls_verify 1 -ca_file "$MEDIA_TLS_CA_CERT" \
    -show_entries stream=index -of csv=p=0 "$canonical_url" \
    </dev/null >"$diagnostic_dir/read.log" 2>&1; then
    echo "Jetson publish account unexpectedly has read access." >&2
    exit 1
fi
echo "[OK] Jetson account cannot read the published stream."

if ! wait "$publisher_pid"; then
    publisher_pid=
    echo "Authenticated canonical RTSPS publish did not complete cleanly." >&2
    exit 1
fi
publisher_pid=
echo "[OK] Authenticated canonical RTSPS publish succeeded."

if publish_sample "$denied_url" 1 "$diagnostic_dir/denied.log"; then
    echo "Jetson account unexpectedly published outside live/{UUID}." >&2
    exit 1
fi
echo "[OK] Non-UUID publish path was denied."
echo "MediaMTX publish-only account diagnostic passed."
