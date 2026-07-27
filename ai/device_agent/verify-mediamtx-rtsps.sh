#!/usr/bin/env bash

set -Eeuo pipefail

ENV_FILE="${1:-/etc/william-james/device-agent.env}"
if [[ ! -r "$ENV_FILE" ]]; then
    echo "Environment file is not readable: ${ENV_FILE}" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "${MEDIA_PUBLISH_URL_TEMPLATE:-}" ]]; then
    echo "MEDIA_PUBLISH_URL_TEMPLATE is required." >&2
    exit 1
fi

case "$MEDIA_PUBLISH_URL_TEMPLATE" in
    rtsp://127.0.0.1:*|rtsp://localhost:*|rtsp://*@127.0.0.1:*|rtsp://*@localhost:*)
        echo "Using the loopback RTSP rollback tunnel."
        exit 0
        ;;
    rtsps://*) ;;
    *)
        echo "Publish URL is neither direct RTSPS nor the loopback rollback tunnel." >&2
        exit 1
        ;;
esac

if [[ -z "${MEDIA_TLS_CA_CERT:-}" || ! -r "$MEDIA_TLS_CA_CERT" ]]; then
    echo "MEDIA_TLS_CA_CERT is not readable." >&2
    exit 1
fi
if [[ -z "${MEDIA_TLS_CA_SHA256:-}" ]]; then
    echo "MEDIA_TLS_CA_SHA256 is required for direct RTSPS." >&2
    exit 1
fi

# Read the credential-bearing URL only from the environment. Never pass it as a
# process argument or print it in diagnostics.
read -r media_host media_port < <(
    python3 - <<'PY'
import os
from urllib.parse import urlsplit

value = urlsplit(os.environ["MEDIA_PUBLISH_URL_TEMPLATE"])
if (
    value.scheme != "rtsps"
    or not value.hostname
    or value.port is None
    or value.username is None
    or value.password is None
    or value.path != "/live/{stream_id}"
):
    raise SystemExit("MEDIA_PUBLISH_URL_TEMPLATE must be an authenticated canonical RTSPS template")
print(value.hostname, value.port)
PY
)

expected_fingerprint="${MEDIA_TLS_CA_SHA256^^}"
expected_fingerprint="${expected_fingerprint//:/}"
if [[ ! "$expected_fingerprint" =~ ^[0-9A-F]{64}$ ]]; then
    echo "MEDIA_TLS_CA_SHA256 must be a SHA-256 fingerprint." >&2
    exit 1
fi
actual_fingerprint="$(
    openssl x509 -in "$MEDIA_TLS_CA_CERT" -noout -fingerprint -sha256 |
        awk -F= '{print toupper($2)}' |
        tr -d ':'
)"
if [[ "$actual_fingerprint" != "$expected_fingerprint" ]]; then
    echo "MediaMTX CA SHA-256 fingerprint mismatch." >&2
    exit 1
fi

if ! timeout 12 openssl s_client \
    -connect "${media_host}:${media_port}" \
    -servername "$media_host" \
    -CAfile "$MEDIA_TLS_CA_CERT" \
    -verify_hostname "$media_host" \
    -verify_return_error \
    </dev/null >/dev/null 2>&1; then
    echo "MediaMTX certificate chain or hostname verification failed." >&2
    exit 1
fi

FFMPEG_PATH="${FFMPEG_PATH:-/usr/bin/ffmpeg}"
if ! "$FFMPEG_PATH" -hide_banner -h protocol=tls 2>&1 |
    grep -q -e 'tls_verify' -e 'verify'; then
    echo "FFmpeg does not expose the TLS peer-verification option." >&2
    exit 1
fi
if ! "$FFMPEG_PATH" -hide_banner -h protocol=tls 2>&1 |
    grep -q -e 'ca_file' -e 'cafile'; then
    echo "FFmpeg does not expose the TLS CA-file option." >&2
    exit 1
fi

echo "MediaMTX RTSPS chain, hostname, CA fingerprint, and FFmpeg TLS options are valid."
