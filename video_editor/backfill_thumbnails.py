"""이미 저장된 영상에 목록용 미리보기를 뒤늦게 만들어 준다.

앞으로 올라오는 영상은 업로드가 끝나는 순간 백엔드가 워커에 시킨다
(`VideoThumbnailService.requestAsync`). 이 스크립트는 **그 전에 쌓인 영상**을
같은 경로로 한 번 훑는 것이다 — 2026-08-06 기준 READY 303건.

실행(운영 서버에서, editor-api를 새 이미지로 올린 뒤):

    docker exec william-james-postgres-1 sh -c \\
      'psql -U $POSTGRES_USER -d $POSTGRES_DB -t -A -F"|" -c \\
       "SELECT id, storage_key, coalesce(duration_ms,0) FROM videos \\
         WHERE status='"'"'READY'"'"' ORDER BY created_at DESC"' \\
    | docker run --rm -i --network william-james_default \\
        --env-file /home/ubuntu/william-james/secrets/app.env \\
        -v /tmp/backfill_thumbnails.py:/backfill.py \\
        wj-editor-api:latest python3 /backfill.py

**왜 스스로 ffmpeg를 돌지 않고 워커를 부르나**: 같은 일을 하는 코드가 두 벌이
되면 한쪽만 고쳐진다. 백필이 만든 그림과 평소에 만들어지는 그림이 다르면,
목록에서 어떤 칸은 가운데이고 어떤 칸은 아닌 상태가 조용히 남는다. 워커의
`PUT /v1/videos/{id}/thumbnail`을 그대로 부르면 결과가 한 벌이다.

**왜 원본 URL을 여기서 서명하나**: 워커의 MinIO 자격증명은 편집 버킷만 열린다
(영상 버킷은 AccessDenied). 원본을 읽을 권한은 백엔드 쪽 자격증명에 있으므로,
이 스크립트가 그 권한으로 단기 URL을 만들어 워커에 건넨다 — 평소 백엔드가 하는
일과 같다.

다시 돌려도 안전하다. 워커가 같은 키에 덮어쓰므로 실패한 것만 골라 다시 돌릴
필요도 없고, 그냥 전부 다시 돌려도 결과가 같다.
"""

from __future__ import annotations

import os
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import boto3
import httpx
import jwt
from botocore.config import Config as BotoConfig


# 워커 한 대가 만화·분석과 CPU를 나눠 쓴다. 백필이 그것을 굶기면 안 된다.
WORKERS = int(os.environ.get("BACKFILL_WORKERS", "2"))

# 워커 주소. 같은 도커 네트워크 안에서 컨테이너 이름으로 부른다.
WORKER_BASE = os.environ.get(
    "BACKFILL_WORKER_BASE", "http://william-james-editor-api-1:8000"
)

TIMEOUT_SECONDS = float(os.environ.get("BACKFILL_TIMEOUT", "120"))


def _service_token() -> str:
    """워커가 사람 없이 온 호출을 받아 주는 토큰(iss=wj-server, typ=editor-service).

    백엔드가 `VideoThumbnailService`에서 만드는 것과 같은 모양이다. 키도 같다 —
    백엔드의 `JWT_SIGNING_KEY`가 워커의 `EDITOR_JWT_SECRET`이다.
    """
    secret = os.environ.get("JWT_SIGNING_KEY") or os.environ.get("EDITOR_JWT_SECRET")
    if not secret:
        raise SystemExit("JWT_SIGNING_KEY(또는 EDITOR_JWT_SECRET)가 없습니다.")
    now = datetime.now(timezone.utc)
    return jwt.encode(
        {
            "iss": "wj-server",
            "sub": "wj-server",
            "typ": "editor-service",
            "iat": now,
            # 백필은 몇 분 걸린다. 토큰을 건마다 새로 만들지 않으려고 넉넉히 준다.
            "exp": now + timedelta(hours=1),
        },
        secret,
        algorithm="HS256",
    )


def _s3():
    return boto3.client(
        "s3",
        # 서명은 **내부 주소**로 한다. 워커가 같은 네트워크에 있으므로 nginx를
        # 거칠 이유가 없다 — 거치면 공인 경로로 나갔다 들어온다.
        endpoint_url=os.environ.get("S3_ENDPOINT", "http://minio:9000"),
        aws_access_key_id=os.environ["S3_ACCESS_KEY"],
        aws_secret_access_key=os.environ["S3_SECRET_KEY"],
        region_name="us-east-1",
        config=BotoConfig(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def read_rows(stream) -> list[tuple[str, str, int]]:
    """`id|storage_key|duration_ms` 줄을 읽는다. psql -t -A -F'|' 출력 그대로."""
    rows: list[tuple[str, str, int]] = []
    for line in stream:
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) < 3:
            continue
        video_id, storage_key, duration = parts[0], parts[1], parts[2]
        rows.append((video_id, storage_key, int(duration or 0)))
    return rows


def main() -> int:
    rows = read_rows(sys.stdin)
    if not rows:
        print("대상 영상이 없습니다.")
        return 0
    bucket = os.environ.get("S3_BUCKET", "wj-videos")
    s3 = _s3()
    token = _service_token()
    print(f"{len(rows)}건 시작 (동시 {WORKERS})", flush=True)

    done = {"ok": 0, "fail": 0}

    def one(row: tuple[str, str, int]) -> None:
        video_id, storage_key, duration_ms = row
        try:
            url = s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": bucket, "Key": storage_key},
                ExpiresIn=3600,
            )
            response = httpx.put(
                f"{WORKER_BASE}/v1/videos/{video_id}/thumbnail",
                json={"videoUrl": url, "durationMs": duration_ms or None},
                headers={"Authorization": f"Bearer {token}"},
                timeout=TIMEOUT_SECONDS,
            )
            if response.status_code >= 400:
                raise RuntimeError(f"{response.status_code} {response.text[:200]}")
            done["ok"] += 1
            print(f"  ok   {video_id} {response.json().get('bytes')}B", flush=True)
        except Exception as failure:  # noqa: BLE001 — 한 건 실패가 전체를 멈추면 안 된다
            done["fail"] += 1
            print(f"  FAIL {video_id} {failure}", flush=True)

    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        list(pool.map(one, rows))

    print(f"끝: 성공 {done['ok']}건, 실패 {done['fail']}건")
    # 일부 실패는 정상 종료로 본다 — 다시 돌리면 되고, 실패가 배포를 막을 이유는 없다.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
