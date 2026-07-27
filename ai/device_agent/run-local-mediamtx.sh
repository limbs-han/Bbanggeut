#!/usr/bin/env bash

set -Eeuo pipefail

: "${MEDIAMTX_PATH:=/usr/local/bin/mediamtx}"
: "${LOCAL_MEDIAMTX_CONFIG:=/etc/william-james/mediamtx-local.yml}"

if [[ ! -x "$MEDIAMTX_PATH" ]] && command -v mediamtx >/dev/null 2>&1; then
    MEDIAMTX_PATH="$(command -v mediamtx)"
fi
if [[ ! -x "$MEDIAMTX_PATH" ]]; then
    echo "MediaMTX executable not found: ${MEDIAMTX_PATH}" >&2
    exit 1
fi
if [[ ! -r "$LOCAL_MEDIAMTX_CONFIG" ]]; then
    echo "MediaMTX config is not readable: ${LOCAL_MEDIAMTX_CONFIG}" >&2
    exit 1
fi

exec "$MEDIAMTX_PATH" "$LOCAL_MEDIAMTX_CONFIG"
