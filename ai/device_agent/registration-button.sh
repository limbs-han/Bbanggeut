#!/usr/bin/env bash

set -Eeuo pipefail

INSTALL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DEVICE_AGENT_ENV_FILE:-/etc/william-james/device-agent.env}"
if [[ ! -r "$ENV_FILE" ]]; then
    echo "Device environment is not readable: ${ENV_FILE}" >&2
    exit 1
fi

API_BASE_URL="$(
    sed -n 's/^API_BASE_URL=//p' "$ENV_FILE" |
        tail -n 1 |
        sed -e 's/^["'\'']//' -e 's/["'\'']$//'
)"
API_BASE_URL="${API_BASE_URL:-https://i15e201.p.ssafy.io}"

cd "$INSTALL_DIR"

exec "$INSTALL_DIR/venv/bin/python" \
    -m wj_device_agent.provision \
    --api-base-url "$API_BASE_URL" \
    --env-file "$ENV_FILE" \
    registration-code
