#!/usr/bin/env bash

set -Eeuo pipefail

ENV_FILE="${DEVICE_AGENT_ENV_FILE:-/etc/william-james/device-agent.env}"
if [[ ! -r "$ENV_FILE" ]]; then
    echo "Device environment is not readable: ${ENV_FILE}" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

exec /opt/william-james/device-agent/venv/bin/python \
    /opt/william-james/device-agent/registration_button.py
