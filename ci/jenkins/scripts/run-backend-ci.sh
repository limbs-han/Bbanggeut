#!/usr/bin/env bash
set -euo pipefail

: "${TEST_POSTGRES_HOST:?TEST_POSTGRES_HOST is required}"
: "${TEST_POSTGRES_PORT:?TEST_POSTGRES_PORT is required}"
: "${TEST_POSTGRES_ADMIN_DATABASE:?TEST_POSTGRES_ADMIN_DATABASE is required}"
: "${TEST_POSTGRES_ADMIN_USER:?TEST_POSTGRES_ADMIN_USER is required}"
: "${TEST_POSTGRES_PASSWORD_FILE:?TEST_POSTGRES_PASSWORD_FILE is required}"
# 없으면 로그인 시도 제한 통합 테스트가 실패가 아니라 건너뛰기로 지나갑니다.
# 동시 요청 우회를 막았다는 보장이 조용히 검증되지 않는 상태가 되므로
# 선택 사항으로 두지 않습니다.
: "${TEST_REDIS_HOST:?TEST_REDIS_HOST is required}"
: "${TEST_REDIS_PORT:?TEST_REDIS_PORT is required}"
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

cd backend/server
chmod +x gradlew
./gradlew --no-daemon clean test bootJar
