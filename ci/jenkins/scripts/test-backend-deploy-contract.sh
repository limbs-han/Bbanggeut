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
    nginx-wj-upstream.conf \
    prometheus.yml \
    'william-james@.service' \
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

# 객체 저장소 최소 권한 계약: 백엔드·편집 서버가 MinIO root 자격증명으로
# 되돌아가면 유출 시 버킷·정책·계정 관리까지 넘어간다.
if grep -Eq '^S3_ACCESS_KEY=\$MINIO_ROOT_USER' \
  "${repository_root}/backend/deploy/provision-secrets.sh"
then
  echo "백엔드가 MinIO root 자격증명을 사용합니다(provision-secrets.sh)." >&2
  exit 1
fi
grep -Fq 'WJ_BACKEND_ACCESS_KEY' \
  "${repository_root}/backend/deploy/provision-secrets.sh"
grep -Fq 'mc admin policy attach' \
  "${repository_root}/backend/deploy/docker-compose.yml"
if grep -Eq '^ *MINIO_ACCESS_KEY: \$\{MINIO_ROOT_USER\}' \
  "${repository_root}/backend/deploy/docker-compose.yml"
then
  echo "editor-api가 MinIO root 자격증명을 사용합니다(docker-compose.yml)." >&2
  exit 1
fi

# 무중단 배포 계약: 슬롯 전환의 네 조각(upstream 참조, 슬롯별 JAR, 헬스
# 확인 후 전환, 상태 파일 보존)이 하나라도 빠지면 배포가 다시 다운타임을
# 만든다.
grep -Fq 'proxy_pass http://william_james;'   "${repository_root}/backend/deploy/nginx-william-james.conf"
if grep -q 'proxy_pass http://127.0.0.1:8081'   "${repository_root}/backend/deploy/nginx-william-james.conf"
then
  echo "nginx가 백엔드 포트를 직접 가리킵니다 — 무중단 전환이 불가능합니다." >&2
  exit 1
fi
for contract in   'server-%s.jar'   'wait_for_slot_health "${target_port}"'   'write_upstream_port "${target_port}"'   'if [[ ! -f "${nginx_upstream}" ]]; then'
do
  if ! grep -Fq "${contract}"     "${repository_root}/ci/jenkins/server/deploy/wj-deploy-backend"
  then
    echo "배포 스크립트에서 무중단 계약을 찾지 못했습니다: ${contract}" >&2
    exit 1
  fi
done

# 슬롯마다 다른 MQTT client ID를 쓰는지 고정한다. MQTT는 같은 client ID로 새
# 연결이 오면 기존 세션을 끊으므로, 두 슬롯이 겹치는 배포 구간에서 둘이 서로를
# 1초 남짓 주기로 밀어냈다(2026-08-04 05:20~05:21). 그 동안 기기 명령과
# 텔레메트리가 함께 흔들린다.
if ! grep -Fq -e '--app.mqtt.client-id=wj-backend-%i' \
  "${repository_root}/backend/deploy/william-james@.service"
then
  echo "슬롯 유닛이 MQTT client ID를 슬롯별로 나누지 않습니다 — 배포 중 두 슬롯이 서로를 끊습니다." >&2
  exit 1
fi

# 업로드 한도 정합: 서버 선언(500 MiB)보다 nginx가 크게 열려 있으면 초과
# 본문이 MinIO 디스크에 도달한 뒤에야 거절된다.
if ! grep -A 8 'location \^~ /william-james-videos'   "${repository_root}/backend/deploy/nginx-william-james.conf" |
  grep -Fq 'client_max_body_size 512m;'
then
  echo "nginx의 영상 업로드 본문 한도가 서버 선언(500 MiB)과 어긋납니다." >&2
  exit 1
fi
grep -Fq 'MAX_UPLOAD_BYTES = 524_288_000L'   "${repository_root}/backend/server/src/main/java/com/wj/server/video/application/IotVideoService.java"

# nginx location 중복 검사. 병합 사고로 /editor/ 블록이 두 벌 들어가
# nginx -t가 배포 시점에야 실패했다(2026-08-04 배포 #71·#72). 수정자
# (^~, =, ~)만 다른 같은 URI도 nginx는 중복으로 거부하므로 URI 기준으로
# 잡는다.
duplicate_nginx_locations="$(
  grep -oE '^[[:space:]]*location[[:space:]]+[^{]+' \
    "${repository_root}/backend/deploy/nginx-william-james.conf" |
    sed -E 's/^[[:space:]]*location[[:space:]]+(\^~[[:space:]]+|=[[:space:]]+|~\*?[[:space:]]+)?//; s/[[:space:]]+$//' |
    LC_ALL=C sort | uniq -d
)"
if [[ -n "${duplicate_nginx_locations}" ]]; then
  echo "nginx 설정에 중복 location이 있습니다: ${duplicate_nginx_locations}" >&2
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

# editor-api 서비스 이벤트는 전용 보안 체인이어야 한다.
#
# 사용자 체인에 permitAll만 걸면 통과하지 못한다 — permitAll은 인가 규칙이고,
# Bearer 헤더가 실려 오면 그 앞의 인증 필터가 iss=wj-editor 토큰을 액세스
# 토큰으로 검증하려다 실패해 컨트롤러 도달 전에 401을 낸다. 운영에서 편집
# 분석 완료 알림이 이 때문에 한 건도 발송되지 않았다. 두 번 겪지 않도록
# 체인 분리를 계약으로 고정한다.
security_config="${repository_root}/backend/server/src/main/java/com/wj/server/config/SecurityConfig.java"
if ! grep -Fq '.securityMatcher("/api/editor/**")' "${security_config}"
then
  echo "/api/editor/** 전용 보안 체인이 없습니다 — permitAll만으로는 Bearer 헤더가 인증 필터에서 401이 됩니다." >&2
  exit 1
fi
if grep -Fq '.requestMatchers("/api/editor/events").permitAll()' "${security_config}"
then
  echo "사용자 체인에 /api/editor/events permitAll이 되살아났습니다 — 전용 체인으로 처리해야 합니다." >&2
  exit 1
fi

echo "Backend deployment artifact and WebRTC activation contract passed."
