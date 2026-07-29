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

mkdir -p "$(dirname "${output}")"
tar --create --gzip --file "${output}" \
  --directory "${deploy_root}" \
  "${required_files[@]}"

echo "Created backend infrastructure artifact: ${output}"
