#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
사용법:
  DEVICE_PROVISIONING_ADMIN_KEY=... ./create-device-on-server.sh \
    --serial WJ-PI-... --name "거실 Pi" \
    --token-out /secure/path/wj-bootstrap.token

이 스크립트는 EC2에서 실행하세요. 내부 provisioning API는 127.0.0.1에만
연결되어 있으며 외부에 공개하면 안 됩니다.
EOF
}

serial=
name=
model="Raspberry Pi 4"
firmware="0.1.0-pi"
token_out=
api_url="${DEVICE_PROVISIONING_URL:-http://127.0.0.1:8081/internal/admin/devices}"

while (($#)); do
  case "$1" in
    --serial) serial="${2:-}"; shift 2 ;;
    --name) name="${2:-}"; shift 2 ;;
    --model) model="${2:-}"; shift 2 ;;
    --firmware) firmware="${2:-}"; shift 2 ;;
    --token-out) token_out="${2:-}"; shift 2 ;;
    --api-url) api_url="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "알 수 없는 인자입니다: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$serial" || -z "$name" || -z "$token_out" ]]; then
  usage
  exit 1
fi
if [[ -z "${DEVICE_PROVISIONING_ADMIN_KEY:-}" ]]; then
  echo "DEVICE_PROVISIONING_ADMIN_KEY가 설정되지 않았습니다." >&2
  exit 1
fi
if [[ -e "$token_out" ]]; then
  echo "기존 토큰 파일을 덮어쓰지 않습니다: $token_out" >&2
  exit 1
fi
if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then
  echo "curl과 jq가 필요합니다." >&2
  exit 1
fi

response_file="$(mktemp)"
header_file="$(mktemp)"
trap 'rm -f "$response_file" "$header_file"' EXIT
chmod 600 "$header_file"
printf 'X-Provisioning-Key: %s\n' "$DEVICE_PROVISIONING_ADMIN_KEY" >"$header_file"

jq -n \
  --arg serialNumber "$serial" \
  --arg name "$name" \
  --arg model "$model" \
  --arg firmwareVersion "$firmware" \
  '{serialNumber: $serialNumber, name: $name, model: $model, firmwareVersion: $firmwareVersion}' |
  curl --silent --show-error --fail-with-body \
    -H "@$header_file" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "$api_url" >"$response_file"

purpose="$(jq -r '.purpose // empty' "$response_file")"
device_id="$(jq -r '.deviceId // empty' "$response_file")"
token="$(jq -r '.bearerToken // empty' "$response_file")"
expires_at="$(jq -r '.expiresAt // empty' "$response_file")"
if [[ "$purpose" != "BOOTSTRAP" || -z "$device_id" || -z "$token" ]]; then
  echo "Provisioning 응답에 bootstrap 자격증명이 없습니다." >&2
  exit 1
fi

umask 077
printf '%s\n' "$token" >"$token_out"
chmod 600 "$token_out"

echo "기기 생성 완료: $device_id"
echo "Bootstrap 만료 시각: $expires_at"
echo "Bootstrap 토큰을 권한 600으로 저장했습니다: $token_out"
echo "토큰 파일을 Pi로 안전하게 전달하고 enroll-pi.sh를 즉시 실행하세요."
