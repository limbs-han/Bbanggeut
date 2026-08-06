#!/usr/bin/env bash

# 부팅 직후 틀린 시계 위에서 올라온 미디어 체인을 시계가 맞은 뒤 다시 세운다.
#
# 젯슨에는 RTC 배터리가 없다. 부팅하면 커널 시계가 1970년에서 시작하고,
# systemd-timesyncd 가 마지막으로 기록해 둔 시각으로 일단 되돌려 놓는다. 그건
# 지난번 종료 시각이지 지금 시각이 아니다. 서비스는 그 가짜 시계 위에서 올라오고,
# 잠시 뒤 실제 NTP 가 붙으면서 시계가 몇 시간을 한 번에 건너뛴다.
#
# media-source.sh 는 -timestamps abs 와 -copyts 로 벽시계를 그대로 PTS 에 싣는다.
# 이벤트 클립을 녹화 구간에서 잘라내려면 그 성질이 필요하고 tests/test_media_source.py
# 가 이를 고정하므로 플래그를 뺄 수는 없다. 대신 점프가 끝난 뒤 체인을 다시 세운다.
#
# systemd-time-wait-sync 로 부팅을 막는 방법을 쓰지 않는 이유: 그 유닛은
# sysinit.target 을 붙잡기 때문에 인터넷 없이 부팅하면 미디어가 영영 안 올라온다.
# 홈캠에서는 그게 더 나쁜 고장이다. 서비스는 지금처럼 곧바로 띄우고, 동기화가
# 확인되면 그때 다시 세운다.

set -Eeuo pipefail

# systemd-timesyncd 가 실제 동기화에 성공하면 이 파일을 만든다.
: "${CLOCK_GUARD_SYNC_FLAG:=/run/systemd/timesync/synchronized}"
: "${CLOCK_GUARD_TIMEOUT_SECONDS:=900}"
: "${CLOCK_GUARD_POLL_SECONDS:=5}"
# NTP 의 평상시 보정은 1 초 미만이다. 그보다 큰 어긋남만 점프로 본다.
: "${CLOCK_GUARD_JUMP_THRESHOLD_SECONDS:=5}"
# 의존 관계 순서대로 적는다. 소스를 먼저 세워야 로컬 MediaMTX 가 새 스트림을 문다.
: "${CLOCK_GUARD_UNITS:=wj-media-source.service wj-mediamtx-local.service wj-local-recording.service wj-edge-ai-recording.service}"

for name in \
    CLOCK_GUARD_TIMEOUT_SECONDS \
    CLOCK_GUARD_POLL_SECONDS \
    CLOCK_GUARD_JUMP_THRESHOLD_SECONDS; do
    if ! [[ "${!name}" =~ ^[1-9][0-9]*$ ]]; then
        echo "${name} must be a positive integer: ${!name}" >&2
        exit 2
    fi
done

wall_now() {
    date +%s
}

# 단조 시계는 벽시계 점프의 영향을 받지 않는다. 두 시계가 벌어진 만큼이 점프다.
monotonic_now() {
    awk '{print int($1)}' /proc/uptime
}

start_wall="$(wall_now)"
start_mono="$(monotonic_now)"

waited=0
while [[ ! -e "$CLOCK_GUARD_SYNC_FLAG" ]]; do
    if (( waited >= CLOCK_GUARD_TIMEOUT_SECONDS )); then
        echo "시계 동기화를 ${CLOCK_GUARD_TIMEOUT_SECONDS}초 안에 확인하지 못했습니다."
        echo "미디어 체인은 그대로 둡니다. 오프라인 부팅이면 이것이 정상입니다."
        exit 0
    fi
    sleep "$CLOCK_GUARD_POLL_SECONDS"
    waited=$(( waited + CLOCK_GUARD_POLL_SECONDS ))
done

end_wall="$(wall_now)"
end_mono="$(monotonic_now)"
drift=$(( (end_wall - start_wall) - (end_mono - start_mono) ))
if (( drift < 0 )); then
    drift=$(( -drift ))
fi

if (( drift < CLOCK_GUARD_JUMP_THRESHOLD_SECONDS )); then
    echo "시계 점프 없음 (어긋남 ${drift}초). 미디어 체인을 그대로 둡니다."
    exit 0
fi

echo "시계가 ${drift}초 점프했습니다. 미디어 체인을 다시 세웁니다."
restart_failed=0
for unit in $CLOCK_GUARD_UNITS; do
    # 이 기기에서 쓰지 않는 유닛까지 억지로 띄우지 않는다.
    if ! systemctl is-enabled --quiet "$unit" 2>/dev/null \
        && ! systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "  건너뜀 (enable 도 active 도 아님): ${unit}"
        continue
    fi
    # 하나가 실패해도 나머지는 세운다. 소스만 살아나도 라이브는 열린다.
    if systemctl restart "$unit"; then
        echo "  재시작: ${unit}"
    else
        echo "  재시작 실패: ${unit}" >&2
        restart_failed=1
    fi
done

exit "$restart_failed"
