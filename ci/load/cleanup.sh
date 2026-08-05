#!/usr/bin/env bash
# 부하 테스트 뒷정리. 운영 인스턴스 위에서 돌린다.
#
# 무엇을 지워야 하는가:
#
# 1) 업로드 예약 잔여물 — mixed-load.js는 presigned PUT만 하고 /complete를
#    부르지 않는다. UploadStateSweepWorker가 30분 뒤 row를 FAILED로 닫아 주지만
#    **MinIO 객체는 지우지 않는다**. 그대로 두면 디스크에 계속 남는다.
#    (이건 부하 테스트만의 문제가 아니다 — 실제 기기 업로드가 중간에 끊겨도
#    같은 고아 객체가 남는다. 운영 백로그로 올릴 사안이다.)
#
# 2) 분석 캐시 — editor-api는 이미 분석된 영상에 즉시 done을 돌려준다
#    (_load_cached_analyses). 캐시가 남아 있으면 큐 측정이 성립하지 않으므로
#    재측정 전에 지운다. 지워도 데이터 손실은 없다 — 다음 요청에서 다시 만든다.
#
# 3) storage-io.sh 테스트 버킷 — 정상 종료 시 스스로 지우지만, 중단되면 남는다.
#
# 실행 (서버에서):
#   ./cleanup.sh                 # 전부, 확인 프롬프트
#   ./cleanup.sh --uploads --yes # 업로드 잔여물만, 확인 없이
#   ./cleanup.sh --analyses --video-ids-file ids.txt
set -euo pipefail

MINIO_CONTAINER="${MINIO_CONTAINER:-william-james-minio-1}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-william-james-postgres-1}"
VIDEO_BUCKET="${MINIO_VIDEO_BUCKET:-william-james-videos}"
EDIT_BUCKET="${MINIO_EDIT_BUCKET:-william-james-edit}"
TEST_BUCKET="${BUCKET:-wj-loadtest}"
# prepare.sh가 붙이는 제목 접두어. 이 접두어와 비-READY 상태를 동시에
# 만족하는 row만 지운다 — 실제 영상을 지우지 않기 위한 이중 조건이다.
TITLE_PREFIX="${TITLE_PREFIX:-loadtest-}"

do_uploads=0 do_analyses=0 do_bucket=0 assume_yes=0
video_ids_file=""
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --uploads) do_uploads=1 ;;
    --analyses) do_analyses=1 ;;
    --test-bucket) do_bucket=1 ;;
    --video-ids-file) video_ids_file="$2"; shift ;;
    --yes|-y) assume_yes=1 ;;
    *) echo "알 수 없는 인자: $1" >&2; exit 1 ;;
  esac
  shift
done
if [ $((do_uploads + do_analyses + do_bucket)) -eq 0 ]; then
  do_uploads=1 do_analyses=1 do_bucket=1
fi

command -v docker >/dev/null || { echo "docker가 필요하다 — 서버에서 돌릴 것" >&2; exit 1; }

confirm() {
  [ "$assume_yes" -eq 1 ] && return 0
  printf '%s [y/N] ' "$1"
  read -r answer
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

psql_query() {
  docker exec "$POSTGRES_CONTAINER" sh -c \
    "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -qAt -c \"$1\""
}

mc_setup() {
  docker exec "$MINIO_CONTAINER" sh -c \
    'mc alias set cleanup http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null'
}

# ── 1) 업로드 잔여물 ────────────────────────────────────────────────────────
if [ "$do_uploads" -eq 1 ]; then
  echo "== 업로드 잔여물"
  # 스토리지 키는 IotVideoService가 private/{deviceId}/events/{videoId}.mp4 로 만든다.
  rows="$(psql_query "select id || ' ' || device_id from videos \
    where title like '${TITLE_PREFIX}%' and status <> 'READY'")"
  count="$(echo "$rows" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    echo "   지울 것이 없다."
  else
    echo "   대상 ${count}건 (제목 '${TITLE_PREFIX}*' 이고 상태가 READY가 아닌 row)"
    echo "$rows" | head -5 | sed 's/^/     /'
    [ "$count" -gt 5 ] && echo "     … 외 $((count - 5))건"
    if confirm "   MinIO 객체와 DB row를 지운다."; then
      mc_setup
      while IFS=' ' read -r video_id device_id; do
        [ -n "$video_id" ] || continue
        docker exec "$MINIO_CONTAINER" mc rm \
          "cleanup/$VIDEO_BUCKET/private/$device_id/events/$video_id.mp4" \
          >/dev/null 2>&1 || true
      done <<<"$rows"
      deleted="$(psql_query "with removed as (delete from videos \
        where title like '${TITLE_PREFIX}%' and status <> 'READY' returning 1) \
        select count(*) from removed")"
      echo "   객체 삭제 시도 ${count}건, DB row ${deleted}건 삭제"
    else
      echo "   건너뜀"
    fi
  fi
  echo
fi

# ── 2) 분석 캐시 ────────────────────────────────────────────────────────────
if [ "$do_analyses" -eq 1 ]; then
  echo "== 분석 캐시"
  if [ -z "$video_ids_file" ] && [ -f "$script_dir/.work/analysis-targets.json" ]; then
    video_ids_file="$script_dir/.work/analysis-targets.json"
  fi
  if [ -z "$video_ids_file" ] || [ ! -f "$video_ids_file" ]; then
    echo "   대상 목록이 없다 — --video-ids-file 로 지정하거나 prepare.sh의"
    echo "   .work/analysis-targets.json 을 서버로 복사할 것. 건너뛴다."
  else
    if command -v jq >/dev/null && head -c1 "$video_ids_file" | grep -q '\['; then
      ids="$(jq -r '.[].videoId' "$video_ids_file")"
    else
      ids="$(grep -oE '[0-9a-fA-F-]{36}' "$video_ids_file" | sort -u)"
    fi
    count="$(echo "$ids" | grep -c . || true)"
    echo "   대상 ${count}건. 지워도 데이터 손실은 없다 — 다음 요청에서 다시 만든다."
    if [ "$count" -gt 0 ] && confirm "   edit-analyses/ 캐시를 지운다."; then
      mc_setup
      while IFS= read -r video_id; do
        [ -n "$video_id" ] || continue
        docker exec "$MINIO_CONTAINER" mc rm --recursive --force \
          "cleanup/$EDIT_BUCKET/edit-analyses/$video_id/" >/dev/null 2>&1 || true
      done <<<"$ids"
      echo "   삭제 완료"
    else
      echo "   건너뜀"
    fi
  fi
  echo
fi

# ── 3) 테스트 버킷 ──────────────────────────────────────────────────────────
if [ "$do_bucket" -eq 1 ]; then
  echo "== storage-io.sh 테스트 버킷"
  mc_setup
  if docker exec "$MINIO_CONTAINER" mc ls "cleanup/$TEST_BUCKET" >/dev/null 2>&1; then
    if confirm "   버킷 '$TEST_BUCKET' 을 통째로 지운다."; then
      docker exec "$MINIO_CONTAINER" mc rb --force "cleanup/$TEST_BUCKET" >/dev/null
      echo "   삭제 완료"
    else
      echo "   건너뜀"
    fi
  else
    echo "   버킷이 없다 — 지울 것이 없다."
  fi
  echo
fi

echo "정리 끝. 디스크 여유:"
df -h / | tail -1
