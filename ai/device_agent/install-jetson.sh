#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo: sudo ./install-jetson.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR=/opt/william-james/device-agent
CONFIG_DIR=/etc/william-james
SERVICE_USER=williamjames

for command in python3 ffmpeg ssh; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command is missing: ${command}" >&2
        exit 1
    fi
done

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin \
        --groups video,audio "$SERVICE_USER"
else
    usermod -aG video,audio "$SERVICE_USER"
fi

install -d -m 0755 "$INSTALL_DIR" "$CONFIG_DIR/certs"
install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$CONFIG_DIR/ssh"
install -d -m 0755 "$INSTALL_DIR/wj_device_agent"
cp -a "$SCRIPT_DIR/wj_device_agent/." "$INSTALL_DIR/wj_device_agent/"
install -m 0644 "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"
install -m 0755 "$SCRIPT_DIR/media-tunnel.sh" "$INSTALL_DIR/media-tunnel.sh"
install -m 0755 "$SCRIPT_DIR/check-jetson.sh" "$INSTALL_DIR/check-jetson.sh"
install -m 0755 "$SCRIPT_DIR/registration-button.sh" "$INSTALL_DIR/registration-button.sh"
install -m 0644 "$SCRIPT_DIR/registration_button.py" "$INSTALL_DIR/registration_button.py"

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --disable-pip-version-check \
    -r "$INSTALL_DIR/requirements.txt"
chown -R root:root "$INSTALL_DIR"

install -m 0644 "$SCRIPT_DIR/wj-device-agent-jetson.service" \
    /etc/systemd/system/wj-device-agent.service
install -m 0644 "$SCRIPT_DIR/wj-media-tunnel.service" \
    /etc/systemd/system/wj-media-tunnel.service

if [[ ! -e "$CONFIG_DIR/device-agent.env" ]]; then
    install -m 0640 -o root -g "$SERVICE_USER" \
        "$SCRIPT_DIR/device-agent.jetson.env.example" "$CONFIG_DIR/device-agent.env"
    echo "Created ${CONFIG_DIR}/device-agent.env; fill in provisioning and SSH values."
fi

systemctl daemon-reload
systemctl enable wj-media-tunnel.service wj-device-agent.service

cat <<'EOF'
Installed, but services were not started because credentials must be supplied.

1. Edit /etc/william-james/device-agent.env.
2. Copy the MQTT CA, SSH key, and a verified known_hosts entry to the paths there.
3. Run: sudo -u williamjames /opt/william-james/device-agent/check-jetson.sh
4. Run: sudo systemctl start wj-media-tunnel wj-device-agent
EOF
