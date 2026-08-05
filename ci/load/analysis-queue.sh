#!/usr/bin/env bash
# D축 단독 — AI 분석 큐가 얼마나 쌓이고 각 건이 언제 끝나는지 잰다.
#
# editor-api의 분석 워커는 1개다(analysis_jobs.py: ThreadPoolExecutor(max_workers=1)).
# 동시에 N건을 넣으면 순서대로 돌고, submit()에 큐 상한이 없어 전부 수락된다.
# 코드에 남은 단건 실측치는 2분 내외 영상 기준 약 16.4초다
# (음량 0.2 + YAMNet 0.7 + 영상 4.5 + 표정 11).
#
# 이 스크립트가 확인하려는 것 세 가지:
#   1. N건 동시 요청 시 마지막 건이 언제 끝나는가 (= 16.4초 × N 인가)
#   2. 영상 길이에 따라 처리 시간이 어떻게 늘어나는가
#   3. 대기 중인 사용자가 자기 순번을 알 수 있는가  ← 지금은 알 수 없다
#
# 3번이 핵심 발견이다: submit()이 즉시 job을 만들고 status="running",
# stage="download"로 두므로, 큐에서 대기 중인 건과 실제로 처리 중인 건이
# 상태 응답에서 구별되지 않는다. progress가 0을 벗어나는 시점을 대기 종료
# 근사값으로 쓴다.
#
# 실행:
#   ACCESS_TOKEN=<앱 액세스 토큰> ./ci/load/prepare.sh   # 먼저
#   ACCESS_TOKEN=<같은 토큰> ./ci/load/analysis-queue.sh
set -euo pipefail

BASE_URL="${BASE_URL:-https://i15e201.p.ssafy.io}"
ACCESS_TOKEN="${ACCESS_TOKEN:?ACCESS_TOKEN을 설정할 것}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
# 워커 1개 × 8건 × 16.4초 ≈ 2분 12초. 여유를 두고 10분에서 끊는다.
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work_dir="$script_dir/.work"
targets="$work_dir/analysis-targets.json"
out="$work_dir/analysis-queue.csv"

[ -f "$targets" ] || { echo "$targets 가 없다 — prepare.sh를 먼저 돌릴 것" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq가 필요하다" >&2; exit 1; }

now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", b - a}'; }

mapfile -t video_ids < <(jq -r '.[].videoId' "$targets")
mapfile -t source_urls < <(jq -r '.[].sourceUrl' "$targets")
count="${#video_ids[@]}"
echo "분석 ${count}건을 동시에 요청한다."
echo

# 이미 분석된 영상은 즉시 done을 돌려주므로(_load_cached_analyses) 큐를
# 측정하지 못한다. 먼저 걸러 알려 준다 — 측정을 망친 채 진행하는 것보다
# 낫다. 캐시 삭제는 cleanup.sh --analyses.
cached=0
for index in $(seq 0 $((count - 1))); do
  status="$(curl -sS "$BASE_URL/editor/v1/edit-analyses/${video_ids[$index]}" \
    -H "Authorization: Bearer $ACCESS_TOKEN" | jq -r '.status // "?"')"
  [ "$status" = "done" ] && cached=$((cached + 1))
done
if [ "$cached" -gt 0 ]; then
  echo "경고: ${cached}/${count}건이 이미 분석 완료 상태다 — 그만큼 큐 측정이"
  echo "      성립하지 않는다. ./cleanup.sh --analyses 로 캐시를 지우고 다시 볼 것."
  echo
fi

# 동시 요청. 순차로 보내면 앞 건이 이미 처리를 시작해 큐 형성을 못 본다.
declare -a submitted_at
start="$(now)"
for index in $(seq 0 $((count - 1))); do
  submitted_at[$index]="$(now)"
  curl -sS -o /dev/null -X PUT \
    "$BASE_URL/editor/v1/edit-analyses/${video_ids[$index]}" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg u "${source_urls[$index]}" '{sourceUrl: $u}')" &
done
wait
echo "요청 전송 완료. 폴링 시작 (간격 ${POLL_INTERVAL}초)"
echo

declare -a first_progress_at done_at final_status
for index in $(seq 0 $((count - 1))); do
  first_progress_at[$index]=""
  done_at[$index]=""
  final_status[$index]="running"
done

remaining="$count"
while [ "$remaining" -gt 0 ]; do
  spent="$(elapsed "$start" "$(now)")"
  if awk -v s="$spent" -v t="$TIMEOUT_SECONDS" 'BEGIN{exit !(s > t)}'; then
    echo "타임아웃 ${TIMEOUT_SECONDS}초 초과 — 남은 ${remaining}건을 미완료로 기록한다."
    break
  fi

  for index in $(seq 0 $((count - 1))); do
    [ -z "${done_at[$index]}" ] || continue
    snapshot="$(curl -sS "$BASE_URL/editor/v1/edit-analyses/${video_ids[$index]}" \
      -H "Authorization: Bearer $ACCESS_TOKEN")"
    status="$(echo "$snapshot" | jq -r '.status // "?"')"
    progress="$(echo "$snapshot" | jq -r '.progress // 0')"
    stage="$(echo "$snapshot" | jq -r '.stage // "-"')"

    # progress가 0을 벗어난 첫 순간 = 이 건이 워커를 실제로 잡은 시점.
    # 그 전까지는 큐 대기(+ 원본 내려받기)다.
    if [ -z "${first_progress_at[$index]}" ] \
      && awk -v p="$progress" 'BEGIN{exit !(p > 0)}'; then
      first_progress_at[$index]="$(now)"
    fi

    if [ "$status" = "done" ] || [ "$status" = "failed" ]; then
      done_at[$index]="$(now)"
      final_status[$index]="$status"
      remaining=$((remaining - 1))
      printf '  [%2d] %-6s  제출→완료 %6ss  (stage=%s)\n' \
        "$index" "$status" \
        "$(elapsed "${submitted_at[$index]}" "${done_at[$index]}")" "$stage"
    fi
  done
  [ "$remaining" -gt 0 ] && sleep "$POLL_INTERVAL"
done

echo
echo "index,video_id,queue_wait_s,total_s,status" >"$out"
for index in $(seq 0 $((count - 1))); do
  wait_s=""
  [ -n "${first_progress_at[$index]}" ] \
    && wait_s="$(elapsed "${submitted_at[$index]}" "${first_progress_at[$index]}")"
  total_s=""
  [ -n "${done_at[$index]}" ] \
    && total_s="$(elapsed "${submitted_at[$index]}" "${done_at[$index]}")"
  echo "$index,${video_ids[$index]},$wait_s,$total_s,${final_status[$index]}" >>"$out"
done

echo "결과: $out"
echo
echo "읽는 법 — total_s가 16초 부근에서 계단식으로 늘어나면(16, 33, 49 …)"
echo "워커 1개 직렬 처리가 확인된 것이다. queue_wait_s가 total_s의 대부분을"
echo "차지하면 사용자는 '아무 일도 안 일어나는 화면'을 그만큼 보고 있었다는"
echo "뜻이고, 그게 대기 순번·예상시간 응답이 필요한 근거다."
