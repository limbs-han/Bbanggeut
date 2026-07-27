#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo: sudo ./configure-jetson-rtsps.sh" >&2
    exit 1
fi

INSTALL_DIR=/opt/william-james/device-agent
ENV_FILE=/etc/william-james/device-agent.env
ROLLBACK_FILE=/etc/william-james/device-agent.env.rollback
restart_agent=false
arguments=()

for argument in "$@"; do
    case "$argument" in
        --restart)
            restart_agent=true
            ;;
        *)
            arguments+=("$argument")
            ;;
    esac
done

if [[ ! -x "$INSTALL_DIR/venv/bin/python" || ! -f "$ENV_FILE" ]]; then
    echo "Run install-jetson.sh before configuring direct RTSPS." >&2
    exit 1
fi

install -m 0600 -o root -g root "$ENV_FILE" "$ROLLBACK_FILE"

cd "$INSTALL_DIR"
if ! "$INSTALL_DIR/venv/bin/python" -m wj_device_agent.configure_media \
    --env-file "$ENV_FILE" \
    "${arguments[@]}"; then
    install -m 0640 -o root -g williamjames "$ROLLBACK_FILE" "$ENV_FILE"
    echo "Configuration failed; restored ${ENV_FILE}." >&2
    exit 1
fi

chown root:williamjames "$ENV_FILE"
chmod 0640 "$ENV_FILE"

if ! "$INSTALL_DIR/verify-mediamtx-rtsps.sh" "$ENV_FILE"; then
    install -m 0640 -o root -g williamjames "$ROLLBACK_FILE" "$ENV_FILE"
    echo "RTSPS verification failed; restored ${ENV_FILE}." >&2
    exit 1
fi

if "$restart_agent" && systemctl is-active --quiet wj-device-agent; then
    systemctl restart wj-device-agent
    echo "Explicitly restarted wj-device-agent with the verified configuration."
else
    echo "Configuration verified. The agent was not restarted."
    echo "Run the publish diagnostic, then restart explicitly when MQTT v2 is ready."
fi
