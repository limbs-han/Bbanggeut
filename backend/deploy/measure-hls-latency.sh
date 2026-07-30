#!/usr/bin/env bash
# HLS 라이브 재생의 서버 구간 지연을 측정한다.
#
# glass-to-glass 전체 지연 중 이 스크립트가 재는 것은 "인코더가 만든 구간이
# 플레이리스트에 노출되기까지"와 "플레이어가 최소한 버퍼링해야 하는 양"이다.
# 카메라 촬영 시점부터 화면 표시까지의 물리 지연은 MEASURE_LATENCY.md의
# 수동 절차로 따로 재야 한다.
#
# 사용법:
#   ./measure-hls-latency.sh <playlist-url> [측정초 = 60]
#
# playlist-url은 인증된 경로 전체를 그대로 넘긴다. 예:
#   ./measure-hls-latency.sh 'https://i15e201.p.ssafy.io/live/<streamId>/index.m3u8?token=<t>' 90
set -euo pipefail

playlist_url="${1:-}"
duration="${2:-60}"
poll_interval="${POLL_INTERVAL:-0.2}"

if [[ -z "$playlist_url" ]]; then
  echo "사용법: $0 <playlist-url> [측정초]" >&2
  exit 2
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
seen_file="$work_dir/seen"
: >"$seen_file"

now_ms() { date +%s%3N; }

started_ms="$(now_ms)"
deadline_ms=$((started_ms + duration * 1000))

variant="unknown"
target_duration=""
part_target=""
poll_count=0
fetch_failures=0

# 세그먼트가 플레이리스트에 처음 보인 시각과, 그 세그먼트의 인코딩 시각
# (EXT-X-PROGRAM-DATE-TIME)의 차이를 모은다. 이 값이 "구간 완성 대기 시간"이다.
publish_lag_file="$work_dir/publish_lag"
: >"$publish_lag_file"
# 플레이리스트에 실려 있는 총 재생 길이. 플레이어가 라이브 엣지에서
# 뒤로 얼마나 떨어져서 재생을 시작하는지의 하한이다.
depth_file="$work_dir/depth"
: >"$depth_file"

echo "측정 시작: ${duration}초, 폴링 간격 ${poll_interval}초"
echo "대상: ${playlist_url%%\?*}"
echo

while [[ "$(now_ms)" -lt "$deadline_ms" ]]; do
  poll_count=$((poll_count + 1))
  fetched_ms="$(now_ms)"

  if ! body="$(curl --fail --silent --max-time 5 "$playlist_url" 2>/dev/null)"; then
    fetch_failures=$((fetch_failures + 1))
    sleep "$poll_interval"
    continue
  fi

  # 마스터 플레이리스트를 받은 경우 첫 variant로 한 단계 내려간다.
  if grep -q "EXT-X-STREAM-INF" <<<"$body"; then
    child="$(grep -v '^#' <<<"$body" | grep -v '^[[:space:]]*$' | head -1)"
    if [[ -n "$child" ]]; then
      base="${playlist_url%/*}"
      query=""
      [[ "$playlist_url" == *\?* ]] && query="?${playlist_url#*\?}"
      if [[ "$child" == http* ]]; then
        playlist_url="$child"
      else
        playlist_url="${base}/${child%%\?*}${query}"
      fi
      echo "마스터 플레이리스트 감지 → variant로 전환: ${playlist_url##*/}"
      continue
    fi
  fi

  if [[ "$variant" == "unknown" ]]; then
    if grep -q "EXT-X-PART\b\|EXT-X-PART-INF\|EXT-X-PRELOAD-HINT" <<<"$body"; then
      variant="lowLatency"
    elif grep -q "EXT-X-MAP" <<<"$body"; then
      variant="fmp4"
    else
      variant="mpegts"
    fi
    target_duration="$(grep -m1 "EXT-X-TARGETDURATION" <<<"$body" | cut -d: -f2 || true)"
    part_target="$(grep -m1 "EXT-X-PART-INF" <<<"$body" | grep -oE "PART-TARGET=[0-9.]+" | cut -d= -f2 || true)"
  fi

  # 이번 플레이리스트에 담긴 총 길이(초)를 더한다.
  depth="$(grep -oE "^#EXTINF:[0-9.]+" <<<"$body" | cut -d: -f2 | awk '{s+=$1} END {printf "%.3f", s+0}')"
  [[ -n "$depth" ]] && echo "$depth" >>"$depth_file"

  # 세그먼트 URI와 그 직전의 PROGRAM-DATE-TIME을 짝지어 처음 본 것만 기록한다.
  awk -v fetched="$fetched_ms" '
    /^#EXT-X-PROGRAM-DATE-TIME:/ { pdt = substr($0, index($0, ":") + 1); next }
    /^#/ { next }
    /^[[:space:]]*$/ { next }
    { print $0 "\t" pdt "\t" fetched; pdt = "" }
  ' <<<"$body" >"$work_dir/current"

  while IFS=$'\t' read -r uri pdt seen_ms; do
    [[ -z "$uri" ]] && continue
    key="${uri%%\?*}"
    if grep -Fxq "$key" "$seen_file"; then
      continue
    fi
    echo "$key" >>"$seen_file"
    [[ -z "$pdt" ]] && continue
    # PROGRAM-DATE-TIME(ISO8601)을 epoch ms로 바꿔 노출 지연을 구한다.
    if pdt_ms="$(date -d "$pdt" +%s%3N 2>/dev/null)"; then
      lag=$((seen_ms - pdt_ms))
      # 서버·측정기 시계 차이로 음수가 나오면 신뢰할 수 없으므로 버린다.
      if [[ "$lag" -ge 0 && "$lag" -lt 60000 ]]; then
        echo "$lag" >>"$publish_lag_file"
      fi
    fi
  done <"$work_dir/current"

  sleep "$poll_interval"
done

segment_count="$(wc -l <"$seen_file" | tr -d ' ')"

echo "=============================================="
echo " HLS 서버 구간 측정 결과"
echo "=============================================="
echo "variant                : $variant"
[[ -n "$target_duration" ]] && echo "EXT-X-TARGETDURATION   : ${target_duration}s"
[[ -n "$part_target" ]] && echo "EXT-X-PART-INF PART-TARGET: ${part_target}s"
echo "폴링 횟수              : $poll_count (실패 $fetch_failures)"
echo "관측된 신규 세그먼트   : $segment_count"
echo

if [[ -s "$depth_file" ]]; then
  awk '{v[NR]=$1; s+=$1} END {
    n=NR;
    for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(v[j]<v[i]){t=v[i];v[i]=v[j];v[j]=t}
    mid=int((n+1)/2);
    printf "플레이리스트 총 길이   : 평균 %.2fs / 중앙값 %.2fs / 최소 %.2fs\n", s/n, v[mid], v[1]
    printf "  └ 플레이어가 라이브 엣지 뒤로 최소 이만큼 떨어져 시작한다\n"
  }' "$depth_file"
else
  echo "플레이리스트 총 길이   : 측정 실패(EXTINF 없음)"
fi
echo

if [[ -s "$publish_lag_file" ]]; then
  awk '{v[NR]=$1; s+=$1} END {
    n=NR;
    for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(v[j]<v[i]){t=v[i];v[i]=v[j];v[j]=t}
    mid=int((n+1)/2);
    p95=int(n*0.95);
    if (p95 < 1) p95=1;
    printf "구간 노출 지연         : 평균 %.0fms / 중앙값 %.0fms / p95 %.0fms / 최대 %.0fms (n=%d)\n", \
      s/n, v[mid], v[p95], v[n], n
    printf "  └ 인코딩 시각부터 플레이리스트에 실릴 때까지. LL-HLS 전환의 직접 타깃\n"
  }' "$publish_lag_file"
else
  echo "구간 노출 지연         : 측정 불가"
  echo "  └ EXT-X-PROGRAM-DATE-TIME이 없거나 서버와 측정기의 시계가 어긋나 있다."
  echo "    mediamtx.yml에 hlsAlwaysRemux가 켜져 있어도 PDT는 소스에 따라 빠질 수 있다."
fi
echo
echo "위 두 값의 합이 서버가 만드는 지연의 하한이다."
echo "실제 체감 지연은 여기에 카메라·인코딩·네트워크·플레이어 버퍼가 더해진다."
echo "전체 glass-to-glass는 MEASURE_LATENCY.md의 수동 절차로 측정한다."
