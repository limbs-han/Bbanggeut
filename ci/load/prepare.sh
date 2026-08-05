#!/usr/bin/env bash
# 부하 테스트 입력 준비. 부하를 주지 않는다 — 대상 목록과 서명 URL만 모은다.
#
# 왜 별도 단계인가: 인증을 얻는 일과 부하를 만드는 일을 섞으면 k6 스크립트가
# 토큰 만료·기기 자격증명·금고 탐색까지 떠안는다. 그리고 업로드 경로는 기기
# credential(ROLE_DEVICE_OPERATING)이 필요한데 그건 없을 수도 있다 —
# 그 경우 업로드만 빠지고 나머지는 그대로 돌아야 한다.
#
# 산출물(ci/load/.work/):
#   config.json            k6가 쓸 vaultId 등
#   analysis-targets.json  [{videoId, sourceUrl}] — 분석 트리거 대상
#   upload-urls.json       [{uploadUrl, requiredHeaders}] — DEVICE_TOKEN 있을 때만
#   payload.bin            업로드 본문(기본: 실제 클립 크기대 12 MB)
#
# 실행:
#   ACCESS_TOKEN=<앱 액세스 토큰> ./ci/load/prepare.sh
#   ACCESS_TOKEN=... DEVICE_TOKEN=... DEVICE_ID=<uuid> ./ci/load/prepare.sh
#
# 액세스 토큰은 15분 만료다. prepare.sh와 부하 실행 사이를 벌리지 말 것.
set -euo pipefail

BASE_URL="${BASE_URL:-https://i15e201.p.ssafy.io}"
ACCESS_TOKEN="${ACCESS_TOKEN:?ACCESS_TOKEN을 설정할 것 (앱 액세스 토큰)}"
DEVICE_TOKEN="${DEVICE_TOKEN:-}"
DEVICE_ID="${DEVICE_ID:-}"
# 분석 대상 수. 워커가 1개라 2분 영상 1건에 약 16초 걸린다 — 8건이면 큐
# 마지막 작업은 2분 이상 기다리게 된다. 그 대기를 보려는 값이다.
ANALYSIS_TARGETS="${ANALYSIS_TARGETS:-8}"
# 업로드 URL 개수. TTL이 15분이므로 부하 실행 시간보다 넉넉하되 만료 전에
# 다 쓸 수 있는 수로 둔다. k6는 이 목록을 순환한다(같은 키 덮어쓰기 = 재기록).
UPLOAD_URLS="${UPLOAD_URLS:-40}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work_dir="$script_dir/.work"
repo_root="$(cd "$script_dir/../.." && pwd)"

for tool in curl jq openssl; do
  command -v "$tool" >/dev/null || { echo "필요한 도구가 없다: $tool" >&2; exit 1; }
done

mkdir -p "$work_dir"

api() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" "$BASE_URL$path" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H 'Accept: application/json' "$@"
}

# uuidgen이 없는 환경(Git Bash 등)도 있으므로 openssl로 만든다. v4 형식만
# 맞으면 되고 서버는 형식만 본다(sourceEventId @Size≤100, UUID 형식).
make_uuid() {
  local hex
  hex="$(openssl rand -hex 16)"
  printf '%s-%s-4%s-8%s-%s\n' \
    "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:17:3}" "${hex:20:12}"
}

sha256_of() {
  openssl dgst -sha256 -r "$1" | cut -d' ' -f1
}

echo "== 1. 금고 조회"
vaults="$(api GET /api/vaults)"
vault_id="$(echo "$vaults" | jq -r '(.items // .)[0].id // empty')"
if [ -z "$vault_id" ]; then
  echo "금고를 찾지 못했다. 응답: $vaults" >&2
  exit 1
fi
echo "   vaultId=$vault_id"

# 라이브 측정(whep-viewers.py)에 쓸 기기. 금고에 연결된 첫 ONLINE 기기를
# 고른다 — 오프라인 기기로는 세션 생성이 409 DEVICE_OFFLINE로 거부된다.
if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID="$(echo "$vaults" | jq -r '
    [(.items // .)[].devices[]? | select(.status == "ONLINE") | .deviceId][0] // empty')"
  if [ -n "$DEVICE_ID" ]; then
    echo "   deviceId=$DEVICE_ID (ONLINE 기기 자동 선택)"
  else
    echo "   ONLINE 기기가 없다 — 라이브(B축) 측정은 기기를 켠 뒤에 할 것."
  fi
fi

echo "== 2. READY 영상 조회 (분석 대상)"
# GET /api/videos는 deviceId 또는 vaultId 중 정확히 하나가 필수다(없으면 422).
videos="$(api GET "/api/videos?vaultId=$vault_id&size=100")"
ready_ids="$(echo "$videos" | jq -r '[.items[] | select(.status == "READY") | .id] | .[]')"
ready_count="$(echo "$ready_ids" | grep -c . || true)"
if [ "$ready_count" -eq 0 ]; then
  echo "READY 상태 영상이 없다 — 분석 시나리오를 돌릴 수 없다." >&2
  exit 1
fi
echo "   READY 영상 ${ready_count}건 (요청 대상 ${ANALYSIS_TARGETS}건)"

echo "== 3. 재생 URL 발급 (분석 sourceUrl)"
# editor-api는 sourceUrl 호스트를 EDITOR_SOURCE_URL_HOSTS로 제한한다.
# 백엔드가 발급한 presigned URL은 그 호스트를 쓰므로 그대로 통과한다.
: >"$work_dir/analysis-targets.jsonl"
made=0
while IFS= read -r video_id; do
  [ -n "$video_id" ] || continue
  [ "$made" -lt "$ANALYSIS_TARGETS" ] || break
  signed="$(api POST "/api/videos/$video_id/play-url")"
  url="$(echo "$signed" | jq -r '.url // empty')"
  if [ -z "$url" ]; then
    echo "   경고: $video_id 재생 URL 실패 — $signed" >&2
    continue
  fi
  jq -nc --arg v "$video_id" --arg u "$url" '{videoId: $v, sourceUrl: $u}' \
    >>"$work_dir/analysis-targets.jsonl"
  made=$((made + 1))
done <<<"$ready_ids"
jq -sc '.' "$work_dir/analysis-targets.jsonl" >"$work_dir/analysis-targets.json"
rm -f "$work_dir/analysis-targets.jsonl"
echo "   분석 대상 ${made}건"

echo "== 4. 업로드 본문 준비"
payload="$work_dir/payload.bin"
fixture="$repo_root/runtime/production-video-fixtures/owner-edit-01.mp4"
if [ -f "$fixture" ]; then
  # 실제 이벤트 클립(10~16 MB)과 같은 크기·형식을 쓴다. 크기가 곧 디스크
  # 쓰기량이므로 여기서 현실성을 지키는 게 중요하다.
  cp "$fixture" "$payload"
else
  # 픽스처가 없으면 12 MB 무작위 바이트. 업로드는 /complete를 부르지 않으므로
  # 내용이 mp4일 필요는 없다 — 디스크에 쓰이는 바이트 수만 같으면 된다.
  openssl rand -out "$payload" $((12 * 1024 * 1024))
fi
size_bytes="$(wc -c <"$payload" | tr -d ' ')"
checksum="$(sha256_of "$payload")"
echo "   payload=${size_bytes} bytes sha256=${checksum:0:16}…"

echo "== 5. 업로드 URL 발급"
if [ -z "$DEVICE_TOKEN" ] || [ -z "$DEVICE_ID" ]; then
  echo "   DEVICE_TOKEN/DEVICE_ID가 없다 — 업로드 시나리오를 건너뛴다."
  echo "   같은 디스크 경합은 storage-io.sh가 DB 없이 잰다."
  rm -f "$work_dir/upload-urls.json"
else
  : >"$work_dir/upload-urls.jsonl"
  issued=0
  for _ in $(seq 1 "$UPLOAD_URLS"); do
    event_id="$(make_uuid)"
    # capturedStartAt/EndAt은 durationMs와 어긋나도 예약 자체는 통과한다.
    # 완료(API-26)를 부르지 않으므로 무결성 3단 검증까지 가지 않는다.
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    body="$(jq -nc \
      --arg e "$event_id" --arg t "loadtest-$event_id" --arg s "$now" \
      --arg c "$checksum" --argjson b "$size_bytes" \
      '{sourceEventId: $e, triggerType: "MANUAL", title: $t,
        capturedStartAt: $s, capturedEndAt: $s, durationMs: 120000,
        contentType: "video/mp4", sizeBytes: $b, checksumSha256: $c}')"
    response="$(curl -sS -X POST "$BASE_URL/api/iot/videos/upload-url" \
      -H "Authorization: Bearer $DEVICE_TOKEN" \
      -H "Idempotency-Key: $event_id" \
      -H 'Content-Type: application/json' \
      -d "$body")"
    upload_url="$(echo "$response" | jq -r '.uploadUrl // empty')"
    if [ -z "$upload_url" ]; then
      echo "   경고: 업로드 URL 실패 — $response" >&2
      continue
    fi
    echo "$response" | jq -c \
      '{uploadUrl, requiredHeaders: (.requiredHeaders // {}), videoId}' \
      >>"$work_dir/upload-urls.jsonl"
    issued=$((issued + 1))
  done
  jq -sc '.' "$work_dir/upload-urls.jsonl" >"$work_dir/upload-urls.json"
  rm -f "$work_dir/upload-urls.jsonl"
  echo "   업로드 URL ${issued}건 (TTL 15분 — 지금 바로 부하를 돌릴 것)"
fi

jq -nc --arg v "$vault_id" --arg d "$DEVICE_ID" --argjson b "$size_bytes" \
  '{vaultId: $v, deviceId: $d, payloadBytes: $b}' >"$work_dir/config.json"

echo
echo "준비 완료. 다음:"
echo "  docker run --rm --network host \\"
echo "    -e BASE_URL=$BASE_URL -e ACCESS_TOKEN=\"\$ACCESS_TOKEN\" \\"
echo "    -v \"\$PWD/ci/load:/scripts\" grafana/k6 run /scripts/mixed-load.js"
echo
echo "끝난 뒤 반드시: ./ci/load/cleanup.sh"
