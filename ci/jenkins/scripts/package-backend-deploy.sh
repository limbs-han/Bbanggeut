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
  prometheus.yml
  grafana-datasources.yml
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

# editor-api 소스도 함께 담는다. 배포 wrapper 가 서버에서 이미지를 빌드해
# 올리므로 별도 scp 절차가 사라진다. models/ 는 Git 미추적 대용량이라 서버의
# editor-models 디렉터리를 그대로 쓰고, __pycache__ 는 재현성을 해쳐 뺀다.
editor_root="${repo_root}/video_editor"
for file in Dockerfile.local service.py requirements-service.txt requirements-analysis.txt; do
  if [[ ! -s "${editor_root}/${file}" ]]; then
    echo "Required editor-api source file is missing or empty: video_editor/${file}" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "${output}")"
tar --create --gzip --file "${output}" \
  --exclude='video_editor/models' \
  --exclude='video_editor/__pycache__' \
  --exclude='*.pyc' \
  --transform 's|^video_editor|editor-api|' \
  --directory "${deploy_root}" \
  "${required_files[@]}" \
  --directory "$(dirname "${wrapper}")" \
  "$(basename "${wrapper}")" \
  --directory "${repo_root}" \
  video_editor

echo "Created backend infrastructure artifact: ${output}"
