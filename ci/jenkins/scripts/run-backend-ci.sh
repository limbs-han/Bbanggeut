#!/usr/bin/env bash
set -euo pipefail

: "${TEST_POSTGRES_HOST:?TEST_POSTGRES_HOST is required}"
: "${TEST_POSTGRES_PORT:?TEST_POSTGRES_PORT is required}"
: "${TEST_POSTGRES_ADMIN_DATABASE:?TEST_POSTGRES_ADMIN_DATABASE is required}"
: "${TEST_POSTGRES_ADMIN_USER:?TEST_POSTGRES_ADMIN_USER is required}"
: "${TEST_POSTGRES_PASSWORD_FILE:?TEST_POSTGRES_PASSWORD_FILE is required}"
: "${BUILD_NUMBER:?BUILD_NUMBER is required}"
: "${JOB_NAME:?JOB_NAME is required}"

if [[ ! -r "${TEST_POSTGRES_PASSWORD_FILE}" ]]; then
  echo "PostgreSQL CI 비밀번호 파일을 읽을 수 없습니다." >&2
  exit 1
fi

job_hash="$(
  printf '%s' "${JOB_NAME}" |
    sha256sum |
    cut -c1-12
)"
database_name="wj_ci_${job_hash}_${BUILD_NUMBER}"
admin_password="$(<"${TEST_POSTGRES_PASSWORD_FILE}")"

export PGPASSWORD="${admin_password}"

drop_test_database() {
  dropdb \
    --host="${TEST_POSTGRES_HOST}" \
    --port="${TEST_POSTGRES_PORT}" \
    --username="${TEST_POSTGRES_ADMIN_USER}" \
    --maintenance-db="${TEST_POSTGRES_ADMIN_DATABASE}" \
    --if-exists \
    --force \
    "${database_name}"
}

trap drop_test_database EXIT

drop_test_database
createdb \
  --host="${TEST_POSTGRES_HOST}" \
  --port="${TEST_POSTGRES_PORT}" \
  --username="${TEST_POSTGRES_ADMIN_USER}" \
  --maintenance-db="${TEST_POSTGRES_ADMIN_DATABASE}" \
  --owner="${TEST_POSTGRES_ADMIN_USER}" \
  "${database_name}"

export TEST_POSTGRES_JDBC_URL="jdbc:postgresql://${TEST_POSTGRES_HOST}:${TEST_POSTGRES_PORT}/${database_name}"
export TEST_POSTGRES_USER="${TEST_POSTGRES_ADMIN_USER}"
export TEST_POSTGRES_PASSWORD="${admin_password}"

echo "빌드 전용 PostgreSQL 데이터베이스를 생성했습니다: ${database_name}"

# Agent 에는 Docker 소켓이 없어 Testcontainers 로 Redis 를 띄울 수 없습니다.
# 주소가 주어지면 그 인스턴스로 로그인 시도 제한 통합 테스트를 실행하고,
# 없으면 그 테스트만 건너뛴 채 빌드를 계속합니다. 여기서 빌드를 세우면
# redis-ci 를 아직 올리지 않은 Agent 에서 모든 브랜치가 막히기 때문입니다.
if [[ -n "${TEST_REDIS_HOST:-}" && -n "${TEST_REDIS_PORT:-}" ]]; then
  echo "로그인 시도 제한 테스트용 Redis: ${TEST_REDIS_HOST}:${TEST_REDIS_PORT}"
else
  cat >&2 <<'WARNING'
================================================================
경고: TEST_REDIS_HOST / TEST_REDIS_PORT 가 없습니다.
      로그인 시도 제한 통합 테스트가 실행되지 않으며, 동시 요청이
      제한을 우회하지 못한다는 보장이 이 빌드에서 검증되지 않습니다.

      Jenkins 호스트에서 아래를 한 번 실행하면 해결됩니다.
        cd <저장소>/ci/jenkins/server
        docker compose up -d redis-ci
        docker compose up -d --force-recreate backend-agent
================================================================
WARNING
fi

cd backend/server
chmod +x gradlew
./gradlew --no-daemon clean test bootJar
