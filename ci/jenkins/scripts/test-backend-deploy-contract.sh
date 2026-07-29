#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

bash -n \
  "${repository_root}/backend/deploy/provision-secrets.sh" \
  "${repository_root}/ci/jenkins/scripts/package-backend-deploy.sh" \
  "${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"

artifact="${test_root}/backend-deploy.tar.gz"
bash "${repository_root}/ci/jenkins/scripts/package-backend-deploy.sh" \
  "${artifact}"

actual_entries="$(tar --list --gzip --file "${artifact}" | LC_ALL=C sort)"
expected_entries="$(
  printf '%s\n' \
    docker-compose.yml \
    mediamtx.yml \
    mosquitto.conf \
    nginx-william-james.conf |
    LC_ALL=C sort
)"

if [[ "${actual_entries}" != "${expected_entries}" ]]; then
  echo "Backend deployment artifact contract is invalid." >&2
  printf 'Expected:\n%s\nActual:\n%s\n' \
    "${expected_entries}" "${actual_entries}" >&2
  exit 1
fi

grep -Fq \
  'WEBRTC_BASE_URL=https://i15e201.p.ssafy.io/webrtc/live' \
  "${repository_root}/backend/deploy/provision-secrets.sh"
grep -Fq \
  'compose up --detach --pull missing --force-recreate mediamtx' \
  "${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"
grep -Fq \
  'location ~ "^/webrtc/live/' \
  "${repository_root}/backend/deploy/nginx-william-james.conf"

echo "Backend deployment artifact and WebRTC activation contract passed."
