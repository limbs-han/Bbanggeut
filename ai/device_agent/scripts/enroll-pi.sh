#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ./scripts/enroll-pi.sh /path/to/wj-bootstrap.token" >&2
  exit 1
fi

TOKEN_FILE="${1:-}"
API_BASE_URL="${API_BASE_URL:-https://i15e201.p.ssafy.io}"
INSTALL_DIR=/opt/william-james/device-agent
ENV_FILE=/etc/william-james/device-agent.env

if [[ -z "$TOKEN_FILE" ]]; then
  echo "Bootstrap token file is required." >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" || ! -x "$INSTALL_DIR/venv/bin/python" ]]; then
  echo "Run prepare-pi.sh before issuing the 15-minute bootstrap token." >&2
  exit 1
fi
if [[ ! -f /etc/william-james/certs/mqtt-ca.crt ]]; then
  echo "Missing MQTT CA: /etc/william-james/certs/mqtt-ca.crt" >&2
  exit 1
fi
if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "Bootstrap token file does not exist: $TOKEN_FILE" >&2
  exit 1
fi

cd "$INSTALL_DIR"

echo "[1/4] Exchanging one-use bootstrap credential"
"$INSTALL_DIR/venv/bin/python" -m wj_device_agent.provision \
  --api-base-url "$API_BASE_URL" \
  --env-file "$ENV_FILE" \
  enroll --bootstrap-token-file "$TOKEN_FILE"

echo "[2/4] Validating enrolled configuration"
"$INSTALL_DIR/venv/bin/python" -c \
  "import os; from pathlib import Path; from wj_device_agent.provision import read_environment; from wj_device_agent.config import AgentConfig; os.environ.update(read_environment(Path('$ENV_FILE'))); AgentConfig.from_environment(); print('Configuration: OK')" \
  2>/dev/null || {
    echo "Configuration validation failed. Check $ENV_FILE and the MQTT CA path." >&2
    exit 1
  }

echo "[3/4] Starting MQTT device agent"
systemctl enable --now wj-device-agent
sleep 2
systemctl is-active --quiet wj-device-agent || {
  journalctl -u wj-device-agent -n 30 --no-pager >&2
  exit 1
}

echo "[4/4] Issuing the two-minute Flutter registration code"
"$INSTALL_DIR/venv/bin/python" -m wj_device_agent.provision \
  --api-base-url "$API_BASE_URL" \
  --env-file "$ENV_FILE" \
  registration-code

echo
echo "Enter the displayed code in Flutter within two minutes."
echo "After claim, wait up to 30 seconds for the next heartbeat to mark the device ONLINE."
if grep -q 'replace_me' "$ENV_FILE"; then
  echo
  echo "WARNING: MEDIA_PUBLISH_URL_TEMPLATE still contains a placeholder."
  echo "MQTT is online, but live streaming will fail until configure-pi-rtsps.sh is run."
fi
