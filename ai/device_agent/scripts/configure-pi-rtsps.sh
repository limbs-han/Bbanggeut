#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run with sudo: sudo ./scripts/configure-pi-rtsps.sh" >&2
  exit 1
fi

install_dir=/opt/william-james/device-agent
env_file=/etc/william-james/device-agent.env

if [[ ! -x "$install_dir/venv/bin/python" || ! -f "$env_file" ]]; then
  echo "Run prepare-pi.sh before configuring RTSPS." >&2
  exit 1
fi

cd "$install_dir"
"$install_dir/venv/bin/python" -m wj_device_agent.configure_media \
  --env-file "$env_file" \
  "$@"

chmod 600 "$env_file"
if systemctl is-active --quiet wj-device-agent; then
  systemctl restart wj-device-agent
  echo "Restarted wj-device-agent with the new media credential."
fi
