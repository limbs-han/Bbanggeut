#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  DEVICE_PROVISIONING_ADMIN_KEY=... ./create-device-on-server.sh \
    --serial WJ-PI-... --name "Living Room Pi" \
    --token-out /secure/path/wj-bootstrap.token

Run this script on the EC2 host. The internal provisioning endpoint is bound to
127.0.0.1 and must not be exposed publicly.
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
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$serial" || -z "$name" || -z "$token_out" ]]; then
  usage
  exit 1
fi
if [[ -z "${DEVICE_PROVISIONING_ADMIN_KEY:-}" ]]; then
  echo "DEVICE_PROVISIONING_ADMIN_KEY is not set." >&2
  exit 1
fi
if [[ -e "$token_out" ]]; then
  echo "Refusing to overwrite existing token file: $token_out" >&2
  exit 1
fi
if ! command -v jq >/dev/null || ! command -v curl >/dev/null; then
  echo "curl and jq are required." >&2
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
  echo "Provisioning response did not contain a bootstrap credential." >&2
  exit 1
fi

umask 077
printf '%s\n' "$token" >"$token_out"
chmod 600 "$token_out"

echo "Created device: $device_id"
echo "Bootstrap expires at: $expires_at"
echo "Bootstrap token written with mode 600: $token_out"
echo "Transfer the token file securely to the Pi and run enroll-pi.sh immediately."
