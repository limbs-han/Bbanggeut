#!/usr/bin/env bash
set -Eeuo pipefail

state_file="${AUDIO_BENCHMARK_STATE_FILE:-/tmp/wj-audio-benchmark-services.state}"

managed_services=(
  wj-device-agent.service
  wj-local-recording.service
  wj-edge-ai-recording.service
  wj-servo-controller.service
)

required_capture_services=(
  wj-mediamtx-local.service
  wj-media-source.service
)

service_state() {
  systemctl is-active "$1" 2>/dev/null || true
}

print_status() {
  echo "=== AUDIO BENCHMARK SERVICE STATUS ==="
  for service in \
    "${managed_services[@]}" \
    "${required_capture_services[@]}" \
    wj-recording-prune.timer
  do
    printf '%-32s %s\n' "$service" "$(service_state "$service")"
  done
  echo "STATE_FILE=$state_file"
}

isolate() {
  test ! -e "$state_file" || {
    echo "ERROR: isolation state already exists: $state_file" >&2
    exit 1
  }

  temporary="${state_file}.tmp.$$"
  trap 'rm -f -- "$temporary"' EXIT INT TERM
  for service in "${managed_services[@]}"; do
    printf '%s=%s\n' "$service" "$(service_state "$service")" >>"$temporary"
  done
  mv "$temporary" "$state_file"
  trap - EXIT INT TERM

  echo "=== STOP APP, RECORDING, EVENT AI, AND SERVO ==="
  sudo systemctl stop \
    wj-edge-ai-recording.service \
    wj-local-recording.service \
    wj-device-agent.service \
    wj-servo-controller.service

  echo "=== KEEP LOCAL AUDIO CAPTURE PATH READY ==="
  sudo systemctl start \
    wj-mediamtx-local.service \
    wj-media-source.service

  for service in "${managed_services[@]}"; do
    test "$(service_state "$service")" != "active" || {
      echo "ERROR: service did not stop: $service" >&2
      exit 1
    }
  done
  for service in "${required_capture_services[@]}"; do
    test "$(service_state "$service")" = "active" || {
      echo "ERROR: local capture service is not active: $service" >&2
      exit 1
    }
  done
  echo "PASS: app, rolling recording, event upload, and servo are isolated"
  print_status
}

restore() {
  test -f "$state_file" || {
    echo "ERROR: isolation state is missing: $state_file" >&2
    exit 1
  }
  restore_servo=0
  if test "${1:-}" = "--restore-servo"; then
    restore_servo=1
  elif test -n "${1:-}"; then
    echo "ERROR: unsupported restore option: $1" >&2
    exit 1
  fi

  echo "=== RESTORE PREVIOUSLY ACTIVE SERVICES ==="
  while IFS='=' read -r service previous_state; do
    test "$previous_state" = "active" || continue
    if test "$service" = "wj-servo-controller.service" &&
       test "$restore_servo" -ne 1; then
      echo "SERVO_RESTORE_SKIPPED=safety_requires_--restore-servo"
      continue
    fi
    sudo systemctl reset-failed "$service" 2>/dev/null || true
    sudo systemctl start "$service"
  done <"$state_file"

  rm -f -- "$state_file"
  echo "PASS: previously active non-servo services restored"
  print_status
}

usage() {
  echo "Usage: $0 isolate|status|restore [--restore-servo]" >&2
}

case "${1:-}" in
  isolate)
    isolate
    ;;
  status)
    print_status
    ;;
  restore)
    shift
    restore "${1:-}"
    ;;
  *)
    usage
    exit 2
    ;;
esac
