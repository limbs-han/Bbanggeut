#!/usr/bin/env bash
set -euo pipefail

failed=0
check() {
  if ! "$@" >/dev/null 2>&1; then
    echo "FAILED: $*" >&2
    failed=1
  fi
}

check systemctl is-active --quiet william-james
check systemctl is-active --quiet nginx
check curl --fail --silent --max-time 10 http://127.0.0.1:8081/actuator/health

for container in william-james-postgres-1 william-james-minio-1 william-james-mosquitto-1 william-james-mediamtx-1; do
  if [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]]; then
    echo "FAILED: container is not running: $container" >&2
    failed=1
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
  failed=1
fi

exit "$failed"
