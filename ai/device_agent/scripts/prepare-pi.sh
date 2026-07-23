#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ./scripts/prepare-pi.sh [mqtt-ca.crt]" >&2
  exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR=/opt/william-james/device-agent
CONFIG_DIR=/etc/william-james
ENV_FILE="$CONFIG_DIR/device-agent.env"
CA_SOURCE="${1:-}"
MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-1.18.2}"

if [[ ! -f "$SOURCE_DIR/requirements.txt" || ! -d "$SOURCE_DIR/wj_device_agent" ]]; then
  echo "Device-agent source files are incomplete: $SOURCE_DIR" >&2
  exit 1
fi

echo "[1/8] Installing OS prerequisites"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3-venv python3-pip ffmpeg v4l-utils ca-certificates curl

agent_was_enabled=false
if systemctl is-enabled --quiet wj-device-agent 2>/dev/null; then
  agent_was_enabled=true
fi

echo "[2/8] Stopping the agent before replacing its runtime"
systemctl stop wj-device-agent >/dev/null 2>&1 || true

echo "[3/8] Installing device-agent source"
install -d -m 755 "$INSTALL_DIR" "$CONFIG_DIR/certs"
install -d -m 755 "$INSTALL_DIR/wj_device_agent"
cp -a "$SOURCE_DIR/wj_device_agent/." "$INSTALL_DIR/wj_device_agent/"
install -m 644 "$SOURCE_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"
install -m 755 "$SOURCE_DIR/homecam-publisher.sh" "$INSTALL_DIR/homecam-publisher.sh"

echo "[4/8] Creating Python environment"
python3 -m venv --clear "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/python" -m ensurepip
"$INSTALL_DIR/venv/bin/python" -m pip install --disable-pip-version-check \
  -r "$INSTALL_DIR/requirements.txt"

echo "[5/8] Preparing configuration"
if [[ ! -f "$ENV_FILE" ]]; then
  install -m 600 "$SOURCE_DIR/device-agent.pi-rtsps.env.example" "$ENV_FILE"
else
  chmod 600 "$ENV_FILE"
  echo "Keeping existing configuration: $ENV_FILE"
fi
if [[ ! -f "$CONFIG_DIR/homecam-publisher.env" ]]; then
  install -m 644 \
    "$SOURCE_DIR/homecam-publisher.env.example" \
    "$CONFIG_DIR/homecam-publisher.env"
fi
if [[ -n "$CA_SOURCE" ]]; then
  if [[ ! -f "$CA_SOURCE" ]]; then
    echo "MQTT CA file does not exist: $CA_SOURCE" >&2
    exit 1
  fi
  install -m 644 "$CA_SOURCE" "$CONFIG_DIR/certs/mqtt-ca.crt"
fi

echo "[6/8] Installing MediaMTX $MEDIAMTX_VERSION"
case "$(uname -m)" in
  aarch64|arm64) mediamtx_arch=linux_arm64 ;;
  x86_64|amd64) mediamtx_arch=linux_amd64 ;;
  *)
    echo "Unsupported MediaMTX architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
if [[ "$(/usr/local/bin/mediamtx --version 2>/dev/null || true)" != "v$MEDIAMTX_VERSION" ]]; then
  asset="mediamtx_v${MEDIAMTX_VERSION}_${mediamtx_arch}.tar.gz"
  release_url="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}"
  archive="$(mktemp)"
  checksums="$(mktemp)"
  binary="$(mktemp)"
  trap 'rm -f "$archive" "$checksums" "$binary"' EXIT
  curl --fail --location --retry 3 --output "$archive" "$release_url/$asset"
  curl --fail --location --retry 3 --output "$checksums" "$release_url/checksums.sha256"
  expected="$(awk -v asset="$asset" '$2 == asset {print $1}' "$checksums")"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  if [[ -z "$expected" || "$actual" != "$expected" ]]; then
    echo "MediaMTX checksum verification failed for $asset" >&2
    exit 1
  fi
  tar -xOzf "$archive" mediamtx >"$binary"
  install -m 755 "$binary" /usr/local/bin/mediamtx
fi
/usr/local/bin/mediamtx --version

echo "[7/8] Installing systemd units"
install -m 644 "$SOURCE_DIR/mediamtx.pi.yml" "$CONFIG_DIR/mediamtx.yml"
install -m 644 "$SOURCE_DIR/mediamtx.service" /etc/systemd/system/mediamtx.service
install -m 644 \
  "$SOURCE_DIR/homecam-publisher.service" \
  /etc/systemd/system/homecam-publisher.service
install -m 644 "$SOURCE_DIR/wj-device-agent.service" /etc/systemd/system/wj-device-agent.service
systemctl daemon-reload
systemctl enable --now mediamtx
systemctl enable homecam-publisher
if [[ "$agent_was_enabled" == true ]]; then
  systemctl enable --now wj-device-agent
else
  systemctl disable wj-device-agent >/dev/null 2>&1 || true
fi

echo "[8/8] Verifying installation"
cd "$INSTALL_DIR"
"$INSTALL_DIR/venv/bin/python" -c \
  "import paho.mqtt.client; import wj_device_agent; import wj_device_agent.provision; print('Device agent import: OK')"
systemctl is-active --quiet mediamtx
ss -ltn 'sport = :8554'

echo
echo "Preparation complete. No bootstrap token was required."
if [[ ! -s "$CONFIG_DIR/certs/mqtt-ca.crt" ]]; then
  echo "Install the MQTT CA before enrollment:"
  echo "  sudo install -m 0644 mqtt-ca.crt $CONFIG_DIR/certs/mqtt-ca.crt"
fi
echo "Configure the EC2 publish-only MediaMTX credential without putting it in shell history:"
echo "  sudo $SOURCE_DIR/scripts/configure-pi-rtsps.sh"
echo "Then issue a bootstrap token on EC2, transfer its mode-600 file, and run:"
echo "  sudo $SOURCE_DIR/scripts/enroll-pi.sh /home/pi/wj-bootstrap.token"
echo
echo "The camera publisher is enabled for future boots but is not started by this script."
echo "After connecting and configuring the USB camera:"
echo "  sudo systemctl start homecam-publisher"
