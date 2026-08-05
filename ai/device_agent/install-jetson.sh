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
DEPLOYED_COMMIT_FILE="$INSTALL_DIR/DEPLOYED_COMMIT"

for command in python3 ffmpeg openssl ssh; do
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
install -m 0755 "$SCRIPT_DIR/media-source.sh" "$INSTALL_DIR/media-source.sh"
install -m 0755 "$SCRIPT_DIR/check-jetson.sh" "$INSTALL_DIR/check-jetson.sh"
install -m 0755 "$SCRIPT_DIR/test-speaker-output.sh" \
    "$INSTALL_DIR/test-speaker-output.sh"
install -m 0755 "$SCRIPT_DIR/play_talkback_gstreamer.py" \
    "$INSTALL_DIR/play_talkback_gstreamer.py"
install -m 0755 "$SCRIPT_DIR/configure-jetson-rtsps.sh" \
    "$INSTALL_DIR/configure-jetson-rtsps.sh"
install -m 0755 "$SCRIPT_DIR/verify-mediamtx-rtsps.sh" \
    "$INSTALL_DIR/verify-mediamtx-rtsps.sh"
install -m 0755 "$SCRIPT_DIR/diagnose-mediamtx-publish.sh" \
    "$INSTALL_DIR/diagnose-mediamtx-publish.sh"
install -m 0755 "$SCRIPT_DIR/registration-button.sh" "$INSTALL_DIR/registration-button.sh"
install -m 0644 "$SCRIPT_DIR/registration_button.py" "$INSTALL_DIR/registration_button.py"
install -m 0644 "$SCRIPT_DIR/lcd_test.py" "$INSTALL_DIR/lcd_test.py"
install -m 0644 "$SCRIPT_DIR/jetson_registration_button.py" \
    "$INSTALL_DIR/jetson_registration_button.py"
install -m 0644 "$SCRIPT_DIR/servo_test.py" "$INSTALL_DIR/servo_test.py"

if [[ -s "$DEPLOYED_COMMIT_FILE" ]]; then
    install -m 0644 "$DEPLOYED_COMMIT_FILE" "$INSTALL_DIR/PREVIOUS_DEPLOYED_COMMIT"
fi
if deployed_commit="$(git -C "$SCRIPT_DIR" rev-parse --verify HEAD 2>/dev/null)"; then
    printf '%s\n' "$deployed_commit" >"$DEPLOYED_COMMIT_FILE"
    chmod 0644 "$DEPLOYED_COMMIT_FILE"
fi

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --disable-pip-version-check \
    -r "$INSTALL_DIR/requirements.txt"
chown -R root:root "$INSTALL_DIR"

install -m 0644 "$SCRIPT_DIR/wj-device-agent-jetson.service" \
    /etc/systemd/system/wj-device-agent.service
install -m 0644 "$SCRIPT_DIR/wj-media-tunnel.service" \
    /etc/systemd/system/wj-media-tunnel.service
install -m 0644 "$SCRIPT_DIR/wj-media-source.service" \
    /etc/systemd/system/wj-media-source.service
install -m 0644 "$SCRIPT_DIR/wj-registration-button-jetson.service" \
    /etc/systemd/system/wj-registration-button-jetson.service

if [[ ! -e "$CONFIG_DIR/device-agent.env" ]]; then
    install -m 0640 -o root -g "$SERVICE_USER" \
        "$SCRIPT_DIR/device-agent.jetson.env.example" "$CONFIG_DIR/device-agent.env"
    echo "Created ${CONFIG_DIR}/device-agent.env; fill in provisioning and SSH values."
fi

systemctl daemon-reload
systemctl enable wj-media-source.service wj-device-agent.service

cat <<'EOF'
Installed, but services were not started because credentials must be supplied.

1. Edit /etc/william-james/device-agent.env.
2. Install the MQTT CA and verified MediaMTX CA certificate.
3. Run configure-jetson-rtsps.sh with the protected credentials env file.
4. Keep the SSH key and known_hosts files only for rollback.
5. Run: sudo -u williamjames /opt/william-james/device-agent/check-jetson.sh
6. Run diagnose-mediamtx-publish.sh before restarting the agent.
7. Start or restart wj-device-agent only after MQTT v2 ACL validation.
8. After wiring the button and LCD, optionally enable:
   sudo systemctl enable --now wj-registration-button-jetson
DEPLOYED_COMMIT records the installed Git revision; PREVIOUS_DEPLOYED_COMMIT
records the prior one for an explicit checkout-and-reinstall rollback.
EOF
