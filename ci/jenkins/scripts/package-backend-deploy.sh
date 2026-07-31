#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
deploy_root="${repo_root}/backend/deploy"
output="${1:-${repo_root}/backend-deploy.tar.gz}"
required_files=(
  docker-compose.yml
  mediamtx.yml
  mosquitto.conf
  nginx-william-james.conf
)

for file in "${required_files[@]}"; do
  if [[ ! -s "${deploy_root}/${file}" ]]; then
    echo "Required production deployment file is missing or empty: backend/deploy/${file}" >&2
    exit 1
  fi
done

# 배포 스크립트 사본을 함께 담는다. 서버의 /usr/local/sbin 설치본은 Jenkins 가
# 갱신하지 않으므로, 릴리스에 사본이 있어야 설치본이 낡았는지 배포 시점에
# 확인할 수 있다.
wrapper="${repo_root}/ci/jenkins/server/deploy/wj-deploy-backend"
if [[ ! -s "${wrapper}" ]]; then
  echo "Required deployment wrapper is missing or empty: ${wrapper}" >&2
  exit 1
fi

mkdir -p "$(dirname "${output}")"
tar --create --gzip --file "${output}" \
  --directory "${deploy_root}" \
  "${required_files[@]}" \
  --directory "$(dirname "${wrapper}")" \
  "$(basename "${wrapper}")"

echo "Created backend infrastructure artifact: ${output}"
