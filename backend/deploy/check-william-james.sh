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

# 활성 슬롯은 nginx upstream 파일이 가리킨다(무중단 배포). 파일이 없던
# 단일 유닛 시절은 8081이다.
active_port="$(grep -oE '127\.0\.0\.1:[0-9]+' /etc/nginx/conf.d/wj-upstream.conf 2>/dev/null |
  head -1 | cut -d: -f2 || true)"
active_port="${active_port:-8081}"

if ! systemctl is-active --quiet "william-james@${active_port}" &&
  ! systemctl is-active --quiet william-james
then
  echo "FAILED: no backend slot is active (expected william-james@${active_port})" >&2
  failures+=("backend slot ${active_port}")
fi
check systemctl is-active --quiet nginx
check curl --fail --silent --max-time 10 "http://127.0.0.1:${active_port}/actuator/health"
# 공개 경로도 같이 본다 — 슬롯은 살아 있는데 upstream이 엉뚱한 포트를
# 가리키면 사용자에게는 장애다.
check curl --fail --silent --max-time 10 https://i15e201.p.ssafy.io/health
check curl --fail --silent --max-time 10 http://127.0.0.1:18080/health

# 라이브 재생은 nginx auth_request가 백엔드 introspect까지 왕복해야 열린다.
# 이 왕복만 깨지면 /health는 200이라 위 점검을 모두 통과한다 — 2026-08-05에
# 라이브가 12시간 죽어 있었는데도 알림이 없었던 이유다. 없는 토큰에는 401이
# 정답이므로, 401이 아니면 판정 경로 자체가 고장난 것이다(500이면 auth_request가
# 백엔드에서 2xx/401/403이 아닌 응답을 받았다는 뜻).
live_auth_status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
  --request POST --header 'Content-Type: application/sdp' --data-binary 'v=0' \
  'https://i15e201.p.ssafy.io/webrtc/live/00000000-0000-0000-0000-000000000000/whep?token=monitor-probe' ||
  true)"
if [[ "$live_auth_status" != "401" ]]; then
  echo "FAILED: live WHEP auth returned ${live_auth_status} (expected 401)" >&2
  failures+=("live WHEP auth ${live_auth_status}")
fi

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
