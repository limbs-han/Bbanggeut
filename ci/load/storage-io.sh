#!/usr/bin/env bash
# C축 — 저장소 디스크 경합. 운영 인스턴스 위에서 직접 돌린다.
#
# 왜 별도 스크립트인가: mixed-load.js의 업로드 시나리오는 기기
# credential(ROLE_DEVICE_OPERATING)이 있어야 하고, DB에 예약 row를 남긴다.
# 여기서 재려는 건 애플리케이션이 아니라 **디스크**다 — MinIO와 PostgreSQL이
# 같은 EBS 볼륨을 쓰기 때문에 업로드가 몰리면 DB I/O를 굶길 수 있다.
# 그래서 별도 버킷에 직접 써서 인증도 DB도 끼우지 않고 그 경합만 본다.
#
# 부작용: 테스트 버킷에 (PARALLEL × SIZE_MB) MB를 쓴다. 끝나면 지운다.
# 여유 공간을 먼저 확인하고, 모자라면 아무것도 하지 않고 멈춘다.
#
# 실행 (서버에서):
#   ./storage-io.sh              # 기본 8병렬 × 100 MB
#   PARALLEL=20 SIZE_MB=500 ./storage-io.sh   # 최악 케이스
set -euo pipefail

PARALLEL="${PARALLEL:-8}"
SIZE_MB="${SIZE_MB:-100}"
BUCKET="${BUCKET:-wj-loadtest}"
MINIO_CONTAINER="${MINIO_CONTAINER:-william-james-minio-1}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-william-james-postgres-1}"
# 안전 여유. 이 아래로 내려갈 계산이면 실행을 거부한다.
MIN_FREE_GB="${MIN_FREE_GB:-10}"

command -v docker >/dev/null || { echo "docker가 필요하다 — 서버에서 돌릴 것" >&2; exit 1; }
docker inspect "$MINIO_CONTAINER" >/dev/null 2>&1 \
  || { echo "$MINIO_CONTAINER 를 찾을 수 없다" >&2; exit 1; }

total_mb=$((PARALLEL * SIZE_MB))
free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
need_gb=$(( (total_mb / 1024) + MIN_FREE_GB ))
echo "쓸 용량: ${total_mb} MB (${PARALLEL}병렬 × ${SIZE_MB} MB)"
echo "루트 여유: ${free_gb} GB / 필요: ${need_gb} GB (여유분 ${MIN_FREE_GB} GB 포함)"
if [ "$free_gb" -lt "$need_gb" ]; then
  echo "여유 공간이 모자라다 — 실행하지 않는다. PARALLEL/SIZE_MB를 줄일 것." >&2
  exit 1
fi
echo

# 루트 파일시스템의 블록 디바이스. iostat 대상이다.
device="$(df --output=source / | tail -1 | sed 's|/dev/||; s|[0-9]*$||')"

mc() { docker exec "$MINIO_CONTAINER" mc "$@"; }

echo "== 준비"
docker exec "$MINIO_CONTAINER" sh -c \
  'mc alias set loadtest http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null'
mc mb --ignore-existing "loadtest/$BUCKET" >/dev/null
mc anonymous set none "loadtest/$BUCKET" >/dev/null
# 원본 1개를 만들어 N번 복사한다. 매번 /dev/urandom을 읽으면 CPU가 병목이
# 되어 디스크 측정이 오염된다.
docker exec "$MINIO_CONTAINER" sh -c \
  "dd if=/dev/urandom of=/tmp/wj-loadtest.bin bs=1M count=$SIZE_MB status=none"
echo "   버킷=$BUCKET  원본=/tmp/wj-loadtest.bin (${SIZE_MB} MB)"
echo

# ── 기준선: 부하 없는 상태의 DB 지연 ────────────────────────────────────────
db_latency() {
  # 디스크를 실제로 만지는 질의여야 의미가 있다. videos 집계는 부하 중
  # 앱이 실제로 부르는 질의(목록·캘린더)와 같은 테이블을 읽는다.
  docker exec "$POSTGRES_CONTAINER" sh -c \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -qAt -c "\timing on" \
       -c "select count(*) from videos" 2>/dev/null' \
    | grep -o '[0-9.]* ms' | head -1 | tr -d ' ms'
}

echo "== 1. 기준선 (부하 없음)"
baseline=""
for _ in 1 2 3 4 5; do
  value="$(db_latency || true)"
  [ -n "$value" ] && baseline="$baseline $value"
  sleep 1
done
echo "   DB 질의 지연: ${baseline:-측정 실패} ms"
if command -v iostat >/dev/null; then
  echo "   디스크($device) 기준선:"
  iostat -x 1 2 "$device" | tail -3
else
  echo "   iostat이 없다 — sysstat을 설치하면 await/util을 함께 볼 수 있다."
fi
echo

# ── 부하: N병렬 업로드 ──────────────────────────────────────────────────────
echo "== 2. ${PARALLEL}병렬 업로드 중 측정"
if command -v iostat >/dev/null; then
  iostat -x 1 60 "$device" >"/tmp/wj-iostat-$$.txt" 2>/dev/null &
  iostat_pid=$!
else
  iostat_pid=""
fi

load_start="$(date +%s)"
copy_pids=()
for index in $(seq 1 "$PARALLEL"); do
  mc cp /tmp/wj-loadtest.bin "loadtest/$BUCKET/obj-$index.bin" >/dev/null 2>&1 &
  copy_pids+=("$!")
done

# 업로드가 도는 동안 DB 지연을 계속 찍는다 — 경합의 직접 증거다.
# 스크립트에서는 job control(%1)이 꺼져 있으므로 PID로 살아 있는지 본다.
under_load=""
while :; do
  running=0
  for pid in "${copy_pids[@]}"; do
    kill -0 "$pid" 2>/dev/null && running=1 && break
  done
  [ "$running" -eq 1 ] || break
  value="$(db_latency || true)"
  [ -n "$value" ] && under_load="$under_load $value"
  sleep 1
done
wait
load_seconds=$(( $(date +%s) - load_start ))
[ -n "$iostat_pid" ] && { kill "$iostat_pid" 2>/dev/null || true; }

echo "   소요: ${load_seconds}초  처리량: $((total_mb / (load_seconds > 0 ? load_seconds : 1))) MB/s"
echo "   부하 중 DB 질의 지연: ${under_load:-측정 실패} ms"
if [ -n "$iostat_pid" ] && [ -s "/tmp/wj-iostat-$$.txt" ]; then
  # iostat -x의 마지막 열이 %util이다. 100에 붙으면 디스크가 포화 상태다.
  awk -v dev="$device" '$1 == dev && $NF+0 > util { util = $NF+0 }
    END { printf "   디스크 %%util 최대 %.1f\n", util }' "/tmp/wj-iostat-$$.txt"
  echo "   (원본: /tmp/wj-iostat-$$.txt)"
fi
echo

# ── 정리 ────────────────────────────────────────────────────────────────────
echo "== 3. 정리"
mc rb --force "loadtest/$BUCKET" >/dev/null 2>&1 || true
docker exec "$MINIO_CONTAINER" rm -f /tmp/wj-loadtest.bin
echo "   테스트 버킷·임시 파일 삭제 완료"
echo
echo "읽는 법 — 기준선 DB 지연 대비 부하 중 지연이 몇 배로 뛰는지가 핵심이다."
echo "몇 배 이상 벌어지면 MinIO 볼륨을 별도 EBS로 분리(또는 S3 이전)해야 할"
echo "근거가 확보된 것이다. %util이 100에 붙으면 디스크가 이미 포화 상태다."
