#!/usr/bin/env bash

set -Eeuo pipefail

required() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required environment variable: ${name}" >&2
        exit 2
    fi
}

required MEDIA_SSH_HOST
required MEDIA_SSH_KEY
required MEDIA_SSH_KNOWN_HOSTS

MEDIA_SSH_USER="${MEDIA_SSH_USER:-ubuntu}"
MEDIA_SSH_PORT="${MEDIA_SSH_PORT:-22}"
MEDIA_TUNNEL_LOCAL_PORT="${MEDIA_TUNNEL_LOCAL_PORT:-18554}"
MEDIA_TUNNEL_REMOTE_HOST="${MEDIA_TUNNEL_REMOTE_HOST:-127.0.0.1}"
MEDIA_TUNNEL_REMOTE_PORT="${MEDIA_TUNNEL_REMOTE_PORT:-8554}"

if ! [[ "$MEDIA_SSH_PORT" =~ ^[0-9]+$ ]] \
    || ! [[ "$MEDIA_TUNNEL_LOCAL_PORT" =~ ^[0-9]+$ ]] \
    || ! [[ "$MEDIA_TUNNEL_REMOTE_PORT" =~ ^[0-9]+$ ]]; then
    echo "SSH and tunnel ports must be integers." >&2
    exit 2
fi
if [[ ! -r "$MEDIA_SSH_KEY" ]]; then
    echo "SSH private key is not readable: ${MEDIA_SSH_KEY}" >&2
    exit 2
fi
if [[ ! -r "$MEDIA_SSH_KNOWN_HOSTS" ]]; then
    echo "SSH known_hosts is not readable: ${MEDIA_SSH_KNOWN_HOSTS}" >&2
    exit 2
fi

exec /usr/bin/ssh -NT \
    -p "$MEDIA_SSH_PORT" \
    -i "$MEDIA_SSH_KEY" \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$MEDIA_SSH_KNOWN_HOSTS" \
    -L "127.0.0.1:${MEDIA_TUNNEL_LOCAL_PORT}:${MEDIA_TUNNEL_REMOTE_HOST}:${MEDIA_TUNNEL_REMOTE_PORT}" \
    "${MEDIA_SSH_USER}@${MEDIA_SSH_HOST}"
