#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "sudo로 실행하세요: sudo ./scripts/enroll-pi.sh /path/to/wj-bootstrap.token" >&2
  exit 1
fi

TOKEN_FILE="${1:-}"
API_BASE_URL="${API_BASE_URL:-https://i15e201.p.ssafy.io}"
INSTALL_DIR=/opt/william-james/device-agent
ENV_FILE=/etc/william-james/device-agent.env

if [[ -z "$TOKEN_FILE" ]]; then
  echo "Bootstrap 토큰 파일이 필요합니다." >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" || ! -x "$INSTALL_DIR/venv/bin/python" ]]; then
  echo "15분짜리 bootstrap 토큰을 발급하기 전에 prepare-pi.sh를 실행하세요." >&2
  exit 1
fi
if [[ ! -f /etc/william-james/certs/mqtt-ca.crt ]]; then
  echo "MQTT CA가 없습니다: /etc/william-james/certs/mqtt-ca.crt" >&2
  exit 1
fi
if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "Bootstrap 토큰 파일이 없습니다: $TOKEN_FILE" >&2
  exit 1
fi

cd "$INSTALL_DIR"

echo "[1/4] 일회용 bootstrap 자격증명 교환"
"$INSTALL_DIR/venv/bin/python" -m wj_device_agent.provision \
  --api-base-url "$API_BASE_URL" \
  --env-file "$ENV_FILE" \
  enroll --bootstrap-token-file "$TOKEN_FILE"

echo "[2/4] 등록된 설정 검증"
"$INSTALL_DIR/venv/bin/python" -c \
  "import os; from pathlib import Path; from wj_device_agent.provision import read_environment; from wj_device_agent.config import AgentConfig; os.environ.update(read_environment(Path('$ENV_FILE'))); AgentConfig.from_environment(); print('Configuration: OK')" \
  2>/dev/null || {
    echo "설정 검증에 실패했습니다. $ENV_FILE 및 MQTT CA 경로를 확인하세요." >&2
    exit 1
  }

echo "[3/4] MQTT 기기 에이전트 시작"
systemctl enable --now wj-device-agent
sleep 2
systemctl is-active --quiet wj-device-agent || {
  journalctl -u wj-device-agent -n 30 --no-pager >&2
  exit 1
}

echo "[4/4] Flutter용 2분 등록 코드 발급"
"$INSTALL_DIR/venv/bin/python" -m wj_device_agent.provision \
  --api-base-url "$API_BASE_URL" \
  --env-file "$ENV_FILE" \
  registration-code

echo
echo "출력된 코드를 2분 안에 Flutter에 입력하세요."
echo "등록 후 다음 heartbeat가 기기를 ONLINE으로 표시할 때까지 최대 30초 기다리세요."
if grep -q 'replace_me' "$ENV_FILE"; then
  echo
  echo "경고: MEDIA_PUBLISH_URL_TEMPLATE에 아직 예제 값이 남아 있습니다."
  echo "MQTT는 연결되지만 configure-pi-rtsps.sh를 실행하기 전에는 라이브 송출이 실패합니다."
fi
