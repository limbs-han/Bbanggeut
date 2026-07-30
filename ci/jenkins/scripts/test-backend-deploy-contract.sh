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

# HLS 를 끈 상태에서 MediaMTX 는 8888 을 열지 않는다. 준비 검사가 그 포트를
# 요구하면 컨테이너가 정상이어도 배포가 매번 실패한다. 실제로 그렇게 막힌 적이
# 있어 설정과 검사 포트가 어긋나는 것을 여기서 잡는다.
if grep -Eq '^[[:space:]]*hls:[[:space:]]*false([[:space:]]|$)' \
  "${repository_root}/backend/deploy/mediamtx.yml"
then
  if grep -Fq '</dev/tcp/127.0.0.1/8888' \
    "${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"
  then
    echo "mediamtx.yml 이 hls: false 인데 배포 준비 검사가 8888 을 확인합니다." >&2
    exit 1
  fi
fi

# Redis 가 빠지면 로그인 시도 제한이 열린 채로, 기기 presence 는 죽은 채로
# 서비스되는데 배포는 성공으로 보고된다. 눈에 띄지 않는 실패라 계약으로 고정한다.
if ! grep -Eq 'compose up .*--remove-orphans postgres redis minio' \
  "${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"
then
  echo "배포 스크립트가 redis 를 다른 인프라 서비스와 함께 올리지 않습니다." >&2
  exit 1
fi

echo "Backend deployment artifact and WebRTC activation contract passed."
