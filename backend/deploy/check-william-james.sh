#!/usr/bin/env bash
set -euo pipefail

# 5분 주기 상태 점검. 실패는 journal에 남고, WJ_MONITOR_WEBHOOK_URL이
# 설정돼 있으면(서비스 유닛 Environment 또는 EnvironmentFile) 웹훅으로도
# 알린다 — journal에만 남는 실패는 아무도 모른 채 지나간다.
failures=()
check() {
  if ! "$@" >/dev/null 2>&1; then
    echo "FAILED: $*" >&2
    failures+=("$*")
  fi
}

check systemctl is-active --quiet william-james
check systemctl is-active --quiet nginx
check curl --fail --silent --max-time 10 http://127.0.0.1:8081/actuator/health
check curl --fail --silent --max-time 10 http://127.0.0.1:18080/health

for container in \
  william-james-postgres-1 \
  william-james-redis-1 \
  william-james-minio-1 \
  william-james-mosquitto-1 \
  william-james-mediamtx-1 \
  william-james-editor-api-1 \
  william-james-prometheus-1 \
  william-james-grafana-1; do
  if [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]]; then
    echo "FAILED: container is not running: $container" >&2
    failures+=("container: $container")
  fi
done

check bash -c 'timeout 12 openssl s_client \
  -connect i15e201.p.ssafy.io:8322 \
  -servername i15e201.p.ssafy.io \
  -verify_hostname i15e201.p.ssafy.io \
  -verify_return_error </dev/null'

disk_used="$(df -P /home/ubuntu/william-james | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
if [[ "$disk_used" -ge "${WJ_DISK_ALERT_PERCENT:-85}" ]]; then
  echo "FAILED: disk usage is ${disk_used}%" >&2
  failures+=("disk usage ${disk_used}%")
fi

if [[ "${#failures[@]}" -gt 0 && -n "${WJ_MONITOR_WEBHOOK_URL:-}" ]]; then
  summary="$(printf '%s; ' "${failures[@]}")"
  payload="$(printf '{"content": "[빵긋 모니터] 점검 실패 %d건: %s"}' \
    "${#failures[@]}" "${summary% }")"
  curl --silent --max-time 5 \
    -H 'Content-Type: application/json' \
    -d "${payload}" \
    "${WJ_MONITOR_WEBHOOK_URL}" >/dev/null 2>&1 || true
fi

[[ "${#failures[@]}" -eq 0 ]]
