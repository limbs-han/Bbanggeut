#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo: sudo ./configure-jetson-rtsps.sh" >&2
    exit 1
fi

INSTALL_DIR=/opt/william-james/device-agent
ENV_FILE=/etc/william-james/device-agent.env

if [[ ! -x "$INSTALL_DIR/venv/bin/python" || ! -f "$ENV_FILE" ]]; then
    echo "Run install-jetson.sh before configuring direct RTSPS." >&2
    exit 1
fi

cd "$INSTALL_DIR"
"$INSTALL_DIR/venv/bin/python" -m wj_device_agent.configure_media \
    --env-file "$ENV_FILE" \
    "$@"

chown root:williamjames "$ENV_FILE"
chmod 0640 "$ENV_FILE"

if systemctl is-active --quiet wj-device-agent; then
    systemctl restart wj-device-agent
    echo "Restarted wj-device-agent with the direct RTSPS credential."
fi
