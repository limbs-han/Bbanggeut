#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "sudo로 실행하세요: sudo ./scripts/configure-pi-rtsps.sh" >&2
  exit 1
fi

install_dir=/opt/william-james/device-agent
env_file=/etc/william-james/device-agent.env

if [[ ! -x "$install_dir/venv/bin/python" || ! -f "$env_file" ]]; then
  echo "RTSPS 설정 전에 prepare-pi.sh를 실행하세요." >&2
  exit 1
fi

cd "$install_dir"
"$install_dir/venv/bin/python" -m wj_device_agent.configure_media \
  --env-file "$env_file" \
  "$@"

chmod 600 "$env_file"
if systemctl is-active --quiet wj-device-agent; then
  systemctl restart wj-device-agent
  echo "새 미디어 자격증명을 적용하기 위해 wj-device-agent를 재시작했습니다."
fi
