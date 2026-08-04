#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

bash -n \
  "${repository_root}/backend/deploy/provision-secrets.sh" \
  "${repository_root}/ci/jenkins/scripts/package-backend-deploy.sh" \
  "${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"

# Flyway 마이그레이션 버전 중복 검사.
#
# 두 브랜치가 같은 다음 번호를 집어 각각 CI를 통과한 뒤 순서대로 병합되면
# develop에 같은 버전이 둘 생긴다. Flyway는 그때 마이그레이션 목록을 읽는
# 단계에서 거부하므로, 그 버전을 적용하지 않는 호출까지 전부
# FlywayException으로 실패한다 — V35와 V36에서 연달아 겪었다. gradle test까지
# 2분을 기다려 다섯 개가 한꺼번에 터진 로그를 읽는 대신 여기서 1초에 잡는다.
duplicate_migration_versions="$(
  ls "${repository_root}/backend/server/src/main/resources/db/migration" |
    sed -n 's/^V\([0-9][0-9]*\)__.*/\1/p' |
    sort -n |
    uniq -d
)"
if [[ -n "${duplicate_migration_versions}" ]]; then
  echo "Flyway 마이그레이션 버전이 중복됩니다: ${duplicate_migration_versions}" >&2
  echo "develop을 다시 받아 뒤 번호로 옮기고, FlywayMigrationIntegrationTest의" >&2
  echo "최종 스키마 버전도 함께 올리세요." >&2
  exit 1
fi

artifact="${test_root}/backend-deploy.tar.gz"
bash "${repository_root}/ci/jenkins/scripts/package-backend-deploy.sh" \
  "${artifact}"

all_entries="$(tar --list --gzip --file "${artifact}" | LC_ALL=C sort)"
actual_entries="$(printf '%s\n' "${all_entries}" | grep -v '^editor-api/')"
expected_entries="$(
  printf '%s\n' \
    docker-compose.yml \
    grafana-datasources.yml \
    mediamtx.yml \
    mosquitto.conf \
    nginx-william-james.conf \
    prometheus.yml \
    wj-deploy-backend |
    LC_ALL=C sort
)"

if [[ "${actual_entries}" != "${expected_entries}" ]]; then
  echo "Backend deployment artifact contract is invalid." >&2
  printf 'Expected:\n%s\nActual:\n%s\n' \
    "${expected_entries}" "${actual_entries}" >&2
  exit 1
fi

# editor-api 소스가 서버 이미지 빌드에 필요한 파일과 함께 담기는지, 그리고
# 대용량 모델·캐시가 새어 들어오지 않는지 고정한다.
for entry in \
  editor-api/Dockerfile.local \
  editor-api/service.py \
  editor-api/requirements-service.txt \
  editor-api/requirements-analysis.txt
do
  if ! printf '%s\n' "${all_entries}" | grep -Fxq "${entry}"; then
    echo "배포 아티팩트에 editor-api 필수 파일이 없습니다: ${entry}" >&2
    exit 1
  fi
done
if printf '%s\n' "${all_entries}" |
  grep -Eq '^editor-api/models/|__pycache__|\.pyc$'
then
  echo "배포 아티팩트에 editor-api 모델이나 파이썬 캐시가 들어 있습니다." >&2
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

# 발화 URL 기본값은 로컬 개발용 localhost 다. 배포가 이 값을 덮어쓰지 않으면
# 배포는 성공하고 앱만 닿을 수 없는 주소를 받는다. 실제로 한 번 놓쳤다.
grep -Fq \
  'TALKBACK_WHIP_BASE_URL=https://i15e201.p.ssafy.io/webrtc/talkback' \
  "${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"
grep -Fq \
  'TALKBACK_WHIP_BASE_URL=https://i15e201.p.ssafy.io/webrtc/talkback' \
  "${repository_root}/backend/deploy/provision-secrets.sh"
grep -Fq \
  'location ~ "^/webrtc/talkback/' \
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

# 관측성 계약: 메트릭 노출·수집·모니터 웹훅이 빠지면 장애가 다시
# "journal에만 남는" 상태로 돌아간다.
grep -Fq 'micrometer-registry-prometheus' \
  "${repository_root}/backend/server/build.gradle"
grep -Eq 'include: .*prometheus' \
  "${repository_root}/backend/server/src/main/resources/application.yml"
grep -Fq 'compose up --detach --pull missing --remove-orphans postgres redis minio prometheus grafana' \
  "${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"
grep -Fq 'WJ_MONITOR_WEBHOOK_URL' \
  "${repository_root}/backend/deploy/check-william-james.sh"
bash -n "${repository_root}/backend/deploy/check-william-james.sh"

# 유령 세션 대사는 MediaMTX 관리 API 주소가 있어야 켜진다. 배포·프로비저닝이
# 이 값을 채우지 않으면 워커가 조용히 꺼진 채 서비스된다.
grep -Fq 'MEDIAMTX_API_BASE_URL=http://127.0.0.1:9997' \
  "${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"
grep -Fq 'MEDIAMTX_API_BASE_URL=http://127.0.0.1:9997' \
  "${repository_root}/backend/deploy/provision-secrets.sh"
grep -Fq '"127.0.0.1:9997:9997"' \
  "${repository_root}/backend/deploy/docker-compose.yml"
grep -Eq '^api: true' "${repository_root}/backend/deploy/mediamtx.yml"

# editor-api 자동 배포 계약: 서버 빌드, 라이브 교체 전 시크릿 확인, 헬스체크,
# 롤백용 previous 태그가 모두 스크립트에 남아 있어야 한다. 하나라도 빠지면
# 편집 서버가 수동 배포 시절로 소리 없이 되돌아간다.
for contract in \
  'docker build --tag "${editor_image}:next"' \
  'EDITOR_JWT_SECRET=' \
  'editor_health_url="http://127.0.0.1:18080/health"' \
  'docker tag "${editor_image}:latest" "${editor_image}:previous"'
do
  if ! grep -Fq "${contract}" \
    "${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"
  then
    echo "배포 스크립트에서 editor-api 계약을 찾지 못했습니다: ${contract}" >&2
    exit 1
  fi
done

echo "Backend deployment artifact and WebRTC activation contract passed."
