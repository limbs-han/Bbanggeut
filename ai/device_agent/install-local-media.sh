#!/usr/bin/env bash

# Stage the local RTSP and seven-day recording services without starting them.
# The validated UDP services remain active until the operator follows the
# explicit activation and rollback steps printed at the end.

set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo: sudo ./install-local-media.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YOLO_DIR="${SCRIPT_DIR}/../yolo"
INSTALL_DIR=/opt/william-james/device-agent
CONFIG_DIR=/etc/william-james
RECORDING_DIR=/var/lib/william-james/recordings
SERVICE_USER=williamjames

for command in ffmpeg ffprobe mediamtx; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command is missing: ${command}" >&2
        exit 1
    fi
done
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    echo "Service user is missing; run install-jetson.sh first" >&2
    exit 1
fi
if [[ ! -f "${CONFIG_DIR}/device-agent.env" ]]; then
    echo "Missing ${CONFIG_DIR}/device-agent.env; run install-jetson.sh first" >&2
    exit 1
fi

install -d -m 0755 "$INSTALL_DIR" "$CONFIG_DIR"
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$RECORDING_DIR"
install -m 0640 -o "$SERVICE_USER" -g "$SERVICE_USER" /dev/null \
    "${RECORDING_DIR}/.homecam-recordings"

install -m 0755 "$SCRIPT_DIR/media-source.sh" "$INSTALL_DIR/media-source.sh"
install -m 0755 "$SCRIPT_DIR/run-local-mediamtx.sh" \
    "$INSTALL_DIR/run-local-mediamtx.sh"
install -m 0755 "$SCRIPT_DIR/local-recording.sh" \
    "$INSTALL_DIR/local-recording.sh"
install -m 0755 "$SCRIPT_DIR/recording-prune.sh" \
    "$INSTALL_DIR/recording-prune.sh"
install -m 0755 "$SCRIPT_DIR/check-local-media.sh" \
    "$INSTALL_DIR/check-local-media.sh"
install -m 0755 "$SCRIPT_DIR/integration-soak-test.sh" \
    "$INSTALL_DIR/integration-soak-test.sh"
install -m 0644 "$SCRIPT_DIR/mediamtx-local.yml" \
    "$CONFIG_DIR/mediamtx-local.yml"

for unit in \
    wj-mediamtx-local.service \
    wj-local-recording.service \
    wj-recording-prune.service \
    wj-recording-prune.timer; do
    install -m 0644 "$SCRIPT_DIR/$unit" "/etc/systemd/system/$unit"
done
if [[ -f "${YOLO_DIR}/wj-edge-ai-recording.service" ]]; then
    install -m 0644 "${YOLO_DIR}/wj-edge-ai-recording.service" \
        /etc/systemd/system/wj-edge-ai-recording.service
fi

systemctl daemon-reload

cat <<'EOF'
Local media services were installed but not started.

Activate for a non-destructive RTSP trial:
  sudo systemctl restart wj-media-source
  sudo systemctl start wj-mediamtx-local
  sleep 5
  sudo -u williamjames /opt/william-james/device-agent/check-local-media.sh

Start recording after both RTSP paths pass:
  sudo systemctl start wj-local-recording wj-recording-prune.timer

Switch from the 5-second MVP to disk-backed 60-second clips only after a
completed segment is visible:
  sudo systemctl stop wj-edge-ai-mvp
  sudo systemctl start wj-edge-ai-recording

Enable at boot only after the trial is stable:
  sudo systemctl disable wj-edge-ai-mvp
  sudo systemctl enable wj-mediamtx-local \
    wj-local-recording wj-recording-prune.timer wj-edge-ai-recording

Rollback without touching the validated UDP consumers:
  sudo systemctl disable --now wj-edge-ai-recording
  sudo systemctl enable wj-edge-ai-mvp
  sudo systemctl start wj-edge-ai-mvp
  sudo systemctl disable --now wj-local-recording wj-recording-prune.timer \
    wj-mediamtx-local
EOF
