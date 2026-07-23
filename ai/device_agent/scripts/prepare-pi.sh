#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "sudo로 실행하세요: sudo ./scripts/prepare-pi.sh [mqtt-ca.crt]" >&2
  exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR=/opt/william-james/device-agent
CONFIG_DIR=/etc/william-james
ENV_FILE="$CONFIG_DIR/device-agent.env"
CA_SOURCE="${1:-}"
MEDIAMTX_VERSION="${MEDIAMTX_VERSION:-1.18.2}"

if [[ ! -f "$SOURCE_DIR/requirements.txt" || ! -d "$SOURCE_DIR/wj_device_agent" ]]; then
  echo "기기 에이전트 소스 파일이 완전하지 않습니다: $SOURCE_DIR" >&2
  exit 1
fi

echo "[1/8] 운영체제 필수 패키지 설치"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3-venv python3-pip ffmpeg v4l-utils ca-certificates curl

agent_was_enabled=false
if systemctl is-enabled --quiet wj-device-agent 2>/dev/null; then
  agent_was_enabled=true
fi

echo "[2/8] 실행 환경 교체 전 에이전트 중지"
systemctl stop wj-device-agent >/dev/null 2>&1 || true

echo "[3/8] 기기 에이전트 소스 설치"
install -d -m 755 "$INSTALL_DIR" "$CONFIG_DIR/certs"
install -d -m 755 "$INSTALL_DIR/wj_device_agent"
cp -a "$SOURCE_DIR/wj_device_agent/." "$INSTALL_DIR/wj_device_agent/"
install -m 644 "$SOURCE_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"
install -m 755 "$SOURCE_DIR/homecam-publisher.sh" "$INSTALL_DIR/homecam-publisher.sh"

echo "[4/8] Python 가상환경 생성"
python3 -m venv --clear "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/python" -m ensurepip
"$INSTALL_DIR/venv/bin/python" -m pip install --disable-pip-version-check \
  -r "$INSTALL_DIR/requirements.txt"

echo "[5/8] 설정 파일 준비"
if [[ ! -f "$ENV_FILE" ]]; then
  install -m 600 "$SOURCE_DIR/device-agent.pi-rtsps.env.example" "$ENV_FILE"
else
  chmod 600 "$ENV_FILE"
  echo "기존 설정을 유지합니다: $ENV_FILE"
fi
if [[ ! -f "$CONFIG_DIR/homecam-publisher.env" ]]; then
  install -m 644 \
    "$SOURCE_DIR/homecam-publisher.env.example" \
    "$CONFIG_DIR/homecam-publisher.env"
fi
if [[ -n "$CA_SOURCE" ]]; then
  if [[ ! -f "$CA_SOURCE" ]]; then
    echo "MQTT CA 파일이 없습니다: $CA_SOURCE" >&2
    exit 1
  fi
  install -m 644 "$CA_SOURCE" "$CONFIG_DIR/certs/mqtt-ca.crt"
fi

echo "[6/8] MediaMTX $MEDIAMTX_VERSION 설치"
case "$(uname -m)" in
  aarch64|arm64) mediamtx_arch=linux_arm64 ;;
  x86_64|amd64) mediamtx_arch=linux_amd64 ;;
  *)
    echo "지원하지 않는 MediaMTX 아키텍처입니다: $(uname -m)" >&2
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
    echo "MediaMTX 체크섬 검증에 실패했습니다: $asset" >&2
    exit 1
  fi
  tar -xOzf "$archive" mediamtx >"$binary"
  install -m 755 "$binary" /usr/local/bin/mediamtx
fi
/usr/local/bin/mediamtx --version

echo "[7/8] systemd 서비스 설치"
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

echo "[8/8] 설치 결과 검증"
cd "$INSTALL_DIR"
"$INSTALL_DIR/venv/bin/python" -c \
  "import paho.mqtt.client; import wj_device_agent; import wj_device_agent.provision; print('기기 에이전트 모듈 확인: 정상')"
systemctl is-active --quiet mediamtx
ss -ltn 'sport = :8554'

echo
echo "준비가 완료되었습니다. 이 단계에는 bootstrap 토큰이 필요하지 않습니다."
if [[ ! -s "$CONFIG_DIR/certs/mqtt-ca.crt" ]]; then
  echo "Enrollment 전에 MQTT CA를 설치하세요:"
  echo "  sudo install -m 0644 mqtt-ca.crt $CONFIG_DIR/certs/mqtt-ca.crt"
fi
echo "셸 기록에 남기지 않고 EC2 송출 전용 MediaMTX 자격증명을 설정하세요:"
echo "  sudo $SOURCE_DIR/scripts/configure-pi-rtsps.sh"
echo "그다음 EC2에서 bootstrap 토큰을 발급하고 권한 600 파일을 전달한 뒤 실행하세요:"
echo "  sudo $SOURCE_DIR/scripts/enroll-pi.sh /home/pi/wj-bootstrap.token"
echo
echo "카메라 publisher는 부팅 자동 시작으로 등록되지만 이 스크립트에서는 시작하지 않습니다."
echo "USB 카메라를 연결하고 설정한 뒤 실행하세요:"
echo "  sudo systemctl start homecam-publisher"
