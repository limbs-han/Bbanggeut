"""Local HTTP API that exposes the automatic edit recipe to the Flutter app."""

from __future__ import annotations

import base64
import json
import math
import os
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import boto3
import jwt
from botocore.config import Config as BotoConfig
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi import Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from . import backend_access, backend_events
from . import comic
from .adaptive_cli import build_adaptive_recipe
from .adaptive_selector import build_timeline
from .analysis_jobs import (
    ANALYSIS_KINDS,
    AnalysisJobManager,
    AnalysisQueueFull,
    analysis_ready,
)
from .comic_jobs import ComicJobManager, ComicQueueFull


FIXTURE_ROOT = Path(
    os.environ.get("EDITOR_FIXTURE_ROOT", Path(__file__).with_name("fixtures") / "analysis")
)

# 백엔드와 같은 HS256 서명 시크릿(JWT_SIGNING_KEY 값). 있으면 모든 /v1
# 요청에 백엔드 액세스 토큰을 요구한다. 없으면 인증이 꺼진다 — adb reverse
# 루프백 전용인 로컬 개발을 위한 것이고, 실서버 compose는
# EDITOR_REQUIRE_AUTH=true로 시크릿 없는 기동 자체를 막는다.
EDITOR_JWT_SECRET = os.environ.get("EDITOR_JWT_SECRET") or None
if (
    os.environ.get("EDITOR_REQUIRE_AUTH", "false").strip().lower() == "true"
    and EDITOR_JWT_SECRET is None
):
    raise RuntimeError(
        "EDITOR_REQUIRE_AUTH=true인데 EDITOR_JWT_SECRET이 비어 있습니다. "
        "infra/.env에 백엔드 JWT_SIGNING_KEY와 같은 값을 넣으세요."
    )

# 서버 측 원본 내려받기(sourceUrl)를 허용할 호스트. 인증된 사용자라도 이
# 서버가 임의 내부 주소를 대신 요청(SSRF)하게 두지 않는다.
SOURCE_URL_HOSTS = frozenset(
    host.strip()
    for host in os.environ.get(
        "EDITOR_SOURCE_URL_HOSTS", "i15e201.p.ssafy.io"
    ).split(",")
    if host.strip()
)
FIXTURE_PRESETS = {
    "01_20260731_173932": "medium",
    "02_20260731_170944": "medium",
    "03_20260731_153341": "long",
    "04_20260728_104318": "short",
    "05_20260727_162525": "medium",
}


class RecommendationRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    video_id: str = Field(alias="videoId", min_length=1)
    captured_at: datetime | None = Field(default=None, alias="capturedAt")
    duration_preset: str | None = Field(default=None, alias="durationPreset")
    zoom_enabled: bool = Field(default=True, alias="zoomEnabled")


class ProjectSaveRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    recipe: dict[str, Any]
    revision: int = Field(default=1, ge=1)


def _fixture_stem(captured_at: datetime | None) -> str | None:
    if captured_at is None:
        return None
    minute = captured_at.strftime("%Y%m%d_%H%M")
    for stem in FIXTURE_PRESETS:
        if stem[3:16] == minute:
            return stem
    return None


def _read_analysis(stem: str, kind: str) -> dict[str, Any]:
    path = FIXTURE_ROOT / f"{stem}.{kind}.json"
    if not path.is_file():
        raise FileNotFoundError(path)
    return json.loads(path.read_text(encoding="utf-8"))


def _face_track(expression: dict[str, Any]) -> list[dict[str, float]]:
    """앱의 얼굴 추적 스티커가 쓰는 얼굴 궤적.

    expression 분석의 250ms 창에서 얼굴이 잡힌 것만 추린다. 시각은 창의
    가운데(원본 영상 기준 ms), 좌표는 0~1 정규화 얼굴 중심, h는 화면 대비
    얼굴 높이다. 얼굴이 없는 구간은 비워 둔다 — 앱이 이웃 표본을 보간한다.
    """
    track: list[dict[str, float]] = []
    for row in expression.get("expressionWindows", []):
        if int(row.get("faceCount", 0)) <= 0:
            continue
        height = float(row.get("faceHeight", 0.0))
        if height <= 0.0:
            continue
        track.append(
            {
                "ms": (int(row["startMs"]) + int(row["endMs"])) // 2,
                "x": round(float(row.get("focusX", 0.5)), 4),
                "y": round(float(row.get("focusY", 0.5)), 4),
                "h": round(height, 4),
            }
        )
    return track


# 이웃 표본이 이보다 멀리 건너뛰면 같은 사람으로 보지 않는다(0~1 좌표).
_FACE_LINK_DISTANCE = 0.16
# 이보다 오래 끊긴 얼굴은 새 궤적으로 시작한다. 근처에서 다시 잡히면
# 아래 병합 단계가 다시 이어 붙인다.
_FACE_LINK_GAP_MS = 1500
# 이보다 짧게 잡힌 궤적은 오검출로 보고 버린다(250ms 창 4개 = 1초).
_FACE_TRACK_MIN_SAMPLES = 4


def _face_tracks(expression: dict[str, Any]) -> list[dict[str, Any]]:
    """사람별 얼굴 궤적. 앱의 얼굴 추적 스티커가 '누구'를 고를 수 있게 한다.

    v3 분석은 창마다 검출된 얼굴 전부(`faces`)를 남긴다. 창을 시간 순으로
    돌며 각 얼굴을 살아 있는 궤적 중 가장 가까운 것에 붙이고, 붙일 곳이
    없으면 새 궤적을 연다. 옛(v2) 분석은 최강 얼굴 하나만 있으므로 그대로
    한 줄로 잇는다 — 그 경우 사람 구분은 앱의 연속 구간 나누기가 맡는다.
    """
    tracks: list[dict[str, Any]] = []
    for row in expression.get("expressionWindows", []):
        faces = row.get("faces")
        if faces is None:
            if int(row.get("faceCount", 0)) <= 0:
                continue
            faces = [
                {
                    "focusX": row.get("focusX", 0.5),
                    "focusY": row.get("focusY", 0.5),
                    "faceHeight": row.get("faceHeight", 0.0),
                }
            ]
        ms = (int(row["startMs"]) + int(row["endMs"])) // 2
        claimed: set[int] = set()
        for face in faces:
            height = float(face.get("faceHeight", 0.0))
            if height <= 0.0:
                continue
            x = float(face.get("focusX", 0.5))
            y = float(face.get("focusY", 0.5))
            best = None
            best_distance = None
            for candidate in tracks:
                if id(candidate) in claimed:
                    continue
                last = candidate["samples"][-1]
                gap = ms - int(last["ms"])
                if gap > _FACE_LINK_GAP_MS:
                    continue
                allowed = _FACE_LINK_DISTANCE * min(3.0, max(1.0, gap / 250))
                distance = math.hypot(x - last["x"], y - last["y"])
                if distance <= allowed and (
                    best_distance is None or distance < best_distance
                ):
                    best = candidate
                    best_distance = distance
            if best is None:
                best = {"id": f"face-{len(tracks) + 1}", "samples": []}
                tracks.append(best)
            claimed.add(id(best))
            best["samples"].append(
                {"ms": ms, "x": round(x, 4), "y": round(y, 4), "h": round(height, 4)}
            )
    # 오래 자리를 비웠다 같은 자리에서 다시 잡힌 궤적은 같은 사람이다.
    merged: list[dict[str, Any]] = []
    for track in sorted(tracks, key=lambda item: item["samples"][0]["ms"]):
        target = None
        for candidate in merged:
            last = candidate["samples"][-1]
            first = track["samples"][0]
            if int(first["ms"]) <= int(last["ms"]):
                continue
            if (
                math.hypot(first["x"] - last["x"], first["y"] - last["y"])
                <= _FACE_LINK_DISTANCE
            ):
                target = candidate
                break
        if target is None:
            merged.append(track)
        else:
            target["samples"].extend(track["samples"])
    solid = [
        track
        for track in merged
        if len(track["samples"]) >= _FACE_TRACK_MIN_SAMPLES
    ]
    solid.sort(key=lambda item: len(item["samples"]), reverse=True)
    return [
        {"id": f"face-{index + 1}", "samples": track["samples"]}
        for index, track in enumerate(solid)
    ]


def _attach_face_tracks(
    recipe: dict[str, Any], expression: dict[str, Any]
) -> dict[str, Any]:
    face_tracks = _face_tracks(expression)
    recipe["faceTracks"] = face_tracks
    # 하위 호환: 옛 앱은 한 줄짜리 faceTrack만 읽는다. 가장 오래 잡힌
    # 사람의 궤적을 준다 — 최강 표정을 오가던 예전 초점보다 안정적이다.
    recipe["faceTrack"] = (
        face_tracks[0]["samples"] if face_tracks else _face_track(expression)
    )
    return recipe


def build_fixture_recommendation(request: RecommendationRequest) -> dict[str, Any]:
    stem = _fixture_stem(request.captured_at)
    if stem is None:
        raise KeyError("no fixture matches capturedAt")
    preset = request.duration_preset or FIXTURE_PRESETS[stem]
    if preset not in {"auto", "short", "medium", "long"}:
        raise ValueError("durationPreset must be auto, short, medium, or long")
    expression = _read_analysis(stem, "expression")
    recipe = build_adaptive_recipe(
        _read_analysis(stem, "yamnet"),
        _read_analysis(stem, "audio"),
        _read_analysis(stem, "video"),
        expression,
        duration_preset=preset,
        zoom_enabled=request.zoom_enabled,
    )
    recipe["videoId"] = request.video_id
    recipe["fixture"] = stem
    return _attach_face_tracks(recipe, expression)


class RecipeStore:
    def __init__(self) -> None:
        self.bucket = os.environ.get("MINIO_BUCKET", "wj-videos")
        self.client = boto3.client(
            "s3",
            endpoint_url=os.environ.get("MINIO_ENDPOINT", "http://minio:9000"),
            aws_access_key_id=os.environ.get("MINIO_ACCESS_KEY", "minioadmin"),
            aws_secret_access_key=os.environ.get("MINIO_SECRET_KEY", "minioadmin"),
            region_name="us-east-1",
        )
        # 편집본 재생용 presigned URL 서명 클라이언트. 백엔드의
        # S3_PUBLIC_ENDPOINT와 같은 방식 — nginx가 버킷 경로를 프록시하므로
        # 공개 호스트 기준으로 서명해야 모바일에서 그대로 재생된다.
        public_endpoint = os.environ.get("EDITOR_PUBLIC_S3_ENDPOINT") or None
        self.public_client = (
            boto3.client(
                "s3",
                endpoint_url=public_endpoint,
                aws_access_key_id=os.environ.get("MINIO_ACCESS_KEY", "minioadmin"),
                aws_secret_access_key=os.environ.get("MINIO_SECRET_KEY", "minioadmin"),
                region_name="us-east-1",
                config=BotoConfig(
                    signature_version="s3v4", s3={"addressing_style": "path"}
                ),
            )
            if public_endpoint
            else None
        )

    def presign_get(self, key: str, expires_seconds: int = 3600) -> str | None:
        """공개 호스트 기준 presigned GET URL. 공개 endpoint 미설정이면 None."""
        if self.public_client is None:
            return None
        return self.public_client.generate_presigned_url(
            "get_object",
            Params={"Bucket": self.bucket, "Key": key},
            ExpiresIn=expires_seconds,
        )

    def ensure_bucket(self) -> None:
        try:
            self.client.head_bucket(Bucket=self.bucket)
        except ClientError:
            self.client.create_bucket(Bucket=self.bucket)

    def put(self, key: str, value: dict[str, Any]) -> None:
        self.ensure_bucket()
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
        self.client.put_object(
            Bucket=self.bucket,
            Key=key,
            Body=body,
            ContentType="application/json",
        )

    def put_bytes(self, key: str, body: bytes, content_type: str) -> None:
        """그림처럼 JSON이 아닌 것을 그대로 넣는다."""
        self.ensure_bucket()
        self.client.put_object(
            Bucket=self.bucket,
            Key=key,
            Body=body,
            ContentType=content_type,
        )

    def get_json(self, key: str) -> dict[str, Any] | None:
        try:
            response = self.client.get_object(Bucket=self.bucket, Key=key)
        except ClientError:
            return None
        return json.loads(response["Body"].read())

    def open_stream(self, key: str) -> tuple[Any, int] | None:
        try:
            response = self.client.get_object(Bucket=self.bucket, Key=key)
        except ClientError:
            return None
        return response["Body"], int(response["ContentLength"])

    def delete(self, key: str) -> None:
        """없는 키를 지워도 조용히 넘어간다 — S3의 DELETE는 멱등이다."""
        self.client.delete_object(Bucket=self.bucket, Key=key)

    def list_keys(self, prefix: str) -> list[dict[str, Any]]:
        self.ensure_bucket()
        paginator = self.client.get_paginator("list_objects_v2")
        items: list[dict[str, Any]] = []
        for page in paginator.paginate(Bucket=self.bucket, Prefix=prefix):
            for entry in page.get("Contents", []):
                items.append(
                    {
                        "key": entry["Key"],
                        "size": int(entry["Size"]),
                        "lastModified": entry["LastModified"].isoformat(),
                    }
                )
        return items


app = FastAPI(title="William James Local Video Editor", version="1.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)
def source_url_allowed(source_url: str) -> bool:
    parsed = urlparse(source_url)
    return parsed.scheme == "https" and parsed.hostname in SOURCE_URL_HOSTS


def verify_bearer(header: str | None) -> str | None:
    """백엔드 액세스 토큰 검증. 통과하면 None, 아니면 거절 사유.

    서명·만료·발급자(iss=wj-server)만 본다 — 라이브 토큰(iss=wj-live)은
    같은 키로 서명돼도 거부된다. 백엔드처럼 세션 상태(sid·tv)를 DB로
    재검증하지는 않으므로 로그아웃 후에도 토큰 수명(15분)까지는 통한다.
    """
    if EDITOR_JWT_SECRET is None:
        return None
    if header is None or not header.lower().startswith("bearer "):
        return "missing bearer token"
    token = header[len("bearer ") :].strip()
    try:
        jwt.decode(
            token,
            EDITOR_JWT_SECRET,
            algorithms=["HS256"],
            issuer="wj-server",
            options={"require": ["exp", "iss", "sub"]},
        )
    except jwt.PyJWTError as failure:
        return f"invalid token: {type(failure).__name__}"
    return None


store = RecipeStore()
jobs = AnalysisJobManager(
    save=lambda video_id, kind, payload: store.put(
        f"edit-analyses/{video_id}/{kind}.json", payload
    ),
    on_done=lambda job: backend_events.analysis_ready(
        job.video_id, job.requested_by
    ),
    # 진행 상태를 백엔드가 들게 한다. 예전에는 이 관리자의 메모리에만 있어서,
    # 워커를 재배포하면 진행 중이던 분석이 "분석한 적 없음"으로 보였다.
    on_start=lambda job: backend_events.analysis_started(
        job.video_id, job.stage, job.requested_by
    ),
    on_progress=lambda job: backend_events.analysis_progress(
        job.video_id, job.stage, job.progress
    ),
    on_failed=lambda job: backend_events.analysis_failed(
        job.video_id, job.error or "", job.requested_by
    ),
)


def _require_video_access(http_request: Request | None, video_id: str) -> None:
    """금고(가족) 범위 검사 — 백엔드가 사용자 토큰으로 판정한다."""
    header = (
        http_request.headers.get("authorization")
        if http_request is not None
        else None
    )
    if not backend_access.can_access_video(header, video_id):
        raise HTTPException(status_code=403, detail="이 영상에 접근할 수 없습니다")


def _accessible(http_request: Request, video_id: str) -> bool:
    return backend_access.can_access_video(
        http_request.headers.get("authorization"), video_id
    )


def _token_subject(http_request: Request | None) -> str | None:
    """토큰의 사용자 UUID(sub). 서명은 미들웨어가 이미 검증했다."""
    if http_request is None:
        return None
    header = http_request.headers.get("authorization") or ""
    if not header.lower().startswith("bearer "):
        return None
    try:
        claims = jwt.decode(
            header[len("bearer ") :].strip(),
            options={"verify_signature": False},
        )
    except jwt.PyJWTError:
        return None
    subject = claims.get("sub")
    return str(subject) if subject else None


def _load_cached_analyses(video_id: str) -> dict[str, dict[str, Any]] | None:
    """MinIO에 저장된 4종 분석 결과. 하나라도 없으면 None."""
    analyses: dict[str, dict[str, Any]] = {}
    for kind in ANALYSIS_KINDS:
        payload = store.get_json(f"edit-analyses/{video_id}/{kind}.json")
        if payload is None:
            return None
        analyses[kind] = payload
    return analyses


@app.middleware("http")
async def require_session(request: Request, call_next):  # type: ignore[no-untyped-def]
    if request.url.path.startswith("/v1"):
        reason = verify_bearer(request.headers.get("authorization"))
        if reason is not None:
            return JSONResponse(status_code=401, content={"detail": reason})
    return await call_next(request)


@app.get("/health")
def health() -> dict[str, Any]:
    ready, reason = analysis_ready()
    return {
        "status": "ok",
        "fixtures": len(FIXTURE_PRESETS),
        "analysis": ready,
        "analysisUnavailableReason": reason,
        "authRequired": EDITOR_JWT_SECRET is not None,
        "vaultScope": backend_access.enabled(),
        "presignedPlayback": store.public_client is not None,
    }


@app.get("/v1/fixtures")
def fixtures() -> dict[str, Any]:
    return {
        "items": [
            {"stem": stem, "durationPreset": preset}
            for stem, preset in FIXTURE_PRESETS.items()
        ]
    }


def _build_analyzed_recommendation(
    request: RecommendationRequest, analyses: dict[str, dict[str, Any]]
) -> dict[str, Any]:
    preset = request.duration_preset or "auto"
    if preset not in {"auto", "short", "medium", "long"}:
        raise ValueError("durationPreset must be auto, short, medium, or long")
    recipe = build_adaptive_recipe(
        analyses["yamnet"],
        analyses["audio"],
        analyses["video"],
        analyses["expression"],
        duration_preset=preset,
        zoom_enabled=request.zoom_enabled,
    )
    recipe["videoId"] = request.video_id
    recipe["analyzed"] = True
    # 새로 분석한 영상도 얼굴 추적 스티커를 쓸 수 있어야 한다.
    return _attach_face_tracks(recipe, analyses["expression"])


@app.post("/v1/edit-recommendations")
def recommend(
    request: RecommendationRequest, http_request: Request = None
) -> dict[str, Any]:
    _require_video_access(http_request, request.video_id)
    try:
        recipe = build_fixture_recommendation(request)
    except (KeyError, FileNotFoundError):
        # 검증 fixture가 아닌 영상 — 업로드해서 분석한 결과가 있으면 그걸 쓴다.
        analyses = _load_cached_analyses(request.video_id)
        if analyses is None:
            job = jobs.get(request.video_id)
            detail = (
                "analysis-running"
                if job is not None and job.status == "running"
                else "analysis-required"
            )
            raise HTTPException(status_code=404, detail=detail) from None
        try:
            recipe = _build_analyzed_recommendation(request, analyses)
        except ValueError as failure:
            raise HTTPException(status_code=422, detail=str(failure)) from failure
    except ValueError as failure:
        raise HTTPException(status_code=422, detail=str(failure)) from failure
    object_key = f"edit-projects/{request.video_id}/auto-v1.json"
    try:
        store.put(object_key, recipe)
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 저장 실패: {failure}") from failure
    return {"recipe": recipe, "storedObjectKey": object_key}


@app.put("/v1/edit-analyses/{video_id}")
async def request_analysis(video_id: str, request: Request) -> JSONResponse:
    """원본을 받아 백그라운드 분석을 시작한다. 두 가지 방식:

    - `application/json` + `{"sourceUrl": ...}` — 서버가 그 주소(백엔드
      presigned URL)에서 직접 내려받는다. 원본이 이미 MinIO에 있는
      실서버에서는 폰이 영상을 다시 올릴 필요가 없다.
    - 그 외 Content-Type — 요청 본문이 원본 MP4 그대로다(로컬 개발).

    202를 받으면 GET으로 상태를 폴링한다. 이미 분석돼 있으면 즉시 done.
    """
    _require_video_access(request, video_id)
    running = jobs.get(video_id)
    if running is not None and running.status == "running":
        return JSONResponse(
            status_code=202,
            content=running.snapshot(position=jobs.position(video_id)),
        )
    if _load_cached_analyses(video_id) is not None:
        # 이미 분석해 둔 영상이다. 백엔드에도 그렇게 남긴다 — V46 이전에 분석한
        # 영상은 상태 행이 없어서, 알려 주지 않으면 앱이 영원히 "분석한 적 없음"을
        # 본다. userId는 비운다: 상태만 남기고 알림은 보내지 않는다(사용자가 청한
        # 적 없는 "분석 완료" 알림이 뜨면 그게 더 이상하다).
        backend_events.analysis_ready(video_id, None)
        return JSONResponse(
            content={"videoId": video_id, "status": "done", "progress": 1.0}
        )
    ready, reason = analysis_ready()
    if not ready:
        raise HTTPException(status_code=503, detail=f"분석 불가: {reason}")

    upload_dir = Path(tempfile.gettempdir()) / "wj-edit-analysis"
    upload_dir.mkdir(parents=True, exist_ok=True)
    video_path = upload_dir / f"{video_id}.mp4"

    content_type = request.headers.get("content-type", "")
    if content_type.split(";")[0].strip() == "application/json":
        try:
            payload = json.loads(await request.body() or b"{}")
        except json.JSONDecodeError as failure:
            raise HTTPException(status_code=422, detail="invalid json") from failure
        source_url = str(payload.get("sourceUrl", ""))
        if not source_url_allowed(source_url):
            raise HTTPException(
                status_code=422,
                detail="sourceUrl은 허용된 호스트의 https 주소여야 합니다",
            )
        try:
            job = jobs.submit(
                video_id,
                video_path,
                source_url=source_url,
                requested_by=_token_subject(request),
            )
        except AnalysisQueueFull as failure:
            # 429다. 5분짜리 서명 URL을 든 채 줄 끝에 세워 두면 차례가 왔을 때
            # 이미 만료되어 있다 — 기다리게 하는 대신 지금 거절한다.
            raise HTTPException(status_code=429, detail=str(failure)) from failure
    else:
        data = await request.body()
        if not data:
            raise HTTPException(status_code=422, detail="empty body")
        video_path.write_bytes(data)
        try:
            job = jobs.submit(
                video_id, video_path, requested_by=_token_subject(request)
            )
        except AnalysisQueueFull as failure:
            raise HTTPException(status_code=429, detail=str(failure)) from failure
    return JSONResponse(
        status_code=202, content=job.snapshot(position=jobs.position(video_id))
    )


@app.get("/v1/edit-analyses/{video_id}")
def analysis_status(video_id: str, http_request: Request = None) -> dict[str, Any]:
    _require_video_access(http_request, video_id)
    job = jobs.get(video_id)
    if job is not None:
        return job.snapshot(position=jobs.position(video_id))
    if _load_cached_analyses(video_id) is not None:
        return {"videoId": video_id, "status": "done", "progress": 1.0}
    return {"videoId": video_id, "status": "none", "progress": 0.0}


@app.put("/v1/edit-projects/{video_id}")
def save_project(
    video_id: str, request: ProjectSaveRequest, http_request: Request = None
) -> dict[str, Any]:
    _require_video_access(http_request, video_id)
    object_key = f"edit-projects/{video_id}/user-v{request.revision}.json"
    payload = {
        "videoId": video_id,
        "revision": request.revision,
        "recipe": request.recipe,
        "savedAt": datetime.now().astimezone().isoformat(),
    }
    try:
        store.put(object_key, payload)
        # 최신 초안을 고정 키에도 둔다 — 불러올 때 목록을 훑지 않는다.
        store.put(f"edit-projects/{video_id}/latest.json", payload)
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 저장 실패: {failure}") from failure
    return {"storedObjectKey": object_key, "revision": request.revision}


@app.get("/v1/edit-projects")
def list_projects(http_request: Request = None) -> dict[str, Any]:
    """편집 중인(초안이 저장된) 영상 목록. 앱의 "이어서 편집"이 쓴다.

    다른 가족의 초안은 백엔드 판정으로 걸러낸다(영상 단위 캐시).
    """
    try:
        keys = store.list_keys("edit-projects/")
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 조회 실패: {failure}") from failure
    items = []
    for entry in keys:
        parts = entry["key"].split("/")
        if len(parts) != 3 or parts[2] != "latest.json":
            continue
        if http_request is not None and not _accessible(http_request, parts[1]):
            continue
        payload = store.get_json(entry["key"]) or {}
        items.append(
            {
                "videoId": parts[1],
                "revision": payload.get("revision", 1),
                "savedAt": payload.get("savedAt") or entry["lastModified"],
            }
        )
    items.sort(key=lambda item: str(item["savedAt"]), reverse=True)
    return {"items": items}


@app.get("/v1/edit-projects/{video_id}")
def load_project(video_id: str, http_request: Request = None) -> dict[str, Any]:
    """가장 최근 사용자 초안. 없으면 404 — 자동 추천은 recommend가 따로 만든다."""
    _require_video_access(http_request, video_id)
    payload = store.get_json(f"edit-projects/{video_id}/latest.json")
    if payload is None:
        raise HTTPException(status_code=404, detail="no saved draft")
    return payload


@app.delete("/v1/edit-projects/{video_id}", status_code=204)
def delete_project(video_id: str, http_request: Request = None) -> Response:
    """저장한 초안을 버린다. 사용자가 "편집 초안 삭제"를 고른 때만 부른다.

    **최신 초안(latest.json)만 지운다.** 개정본(user-v3.json 등)은 남긴다 —
    되돌릴 길을 통째로 없애면 잘못 누른 삭제를 복구할 수 없고, 보관 만료가
    원본과 함께 정리한다.

    없는 초안을 지우라고 해도 204다. 목록을 보고 눌렀는데 그 사이 다른 가족이
    지웠다면 사용자가 원한 상태(초안 없음)가 이미 이뤄진 것이라, 오류로
    돌려주면 화면이 지워지지 않은 것처럼 보인다.
    """
    _require_video_access(http_request, video_id)
    try:
        store.delete(f"edit-projects/{video_id}/latest.json")
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 삭제 실패: {failure}") from failure
    return Response(status_code=204)


# ── AI 자막(전사문) 보관 ────────────────────────────────────────────────
#
# **왜 서버에 두는가**: 전사는 폰에만 캐시됐다. 그래서 같은 영상을 가족 각자가
# 자기 폰에서 다시 돌렸고(같은 결과에 같은 시간), 앱을 다시 깔면 전부 날아갔다.
# 결과는 영상에만 달린 값이라 한 번 만들면 모두가 쓸 수 있다.
#
# 한 사람이 고친 대사도 함께 남는다 — 자막을 고치는 일은 "이 영상에서 무슨 말이
# 나왔는지"를 바로잡는 일이므로 가족 모두에게 바로잡힌 것이 맞다.


class TranscriptSaveRequest(BaseModel):
    lines: list[dict[str, Any]] = Field(default_factory=list)
    """`{startMs, endMs, text}` 목록. 앱의 CaptionLine과 같은 모양이다."""


def _transcript_key(video_id: str) -> str:
    return f"transcripts/{video_id}.json"


@app.put("/v1/transcripts/{video_id}")
def save_transcript(
    video_id: str, request: TranscriptSaveRequest, http_request: Request = None
) -> dict[str, Any]:
    """전사문을 남긴다. 빈 목록은 저장하지 않는다.

    빈 것을 저장하면 다음에 "캐시 적중(내용 없음)"으로 읽혀 재시도가 영구히
    막힌다 — 앱의 로컬 캐시에서 이미 겪은 함정이다(`TranscriptStore._run`).
    """
    _require_video_access(http_request, video_id)
    lines = [line for line in request.lines if str(line.get("text") or "").strip()]
    if not lines:
        raise HTTPException(status_code=422, detail="빈 전사문은 저장하지 않습니다.")
    payload = {
        "videoId": video_id,
        "lines": lines,
        "savedAt": datetime.now().astimezone().isoformat(),
    }
    try:
        store.put(_transcript_key(video_id), payload)
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 저장 실패: {failure}") from failure
    return {"videoId": video_id, "lines": len(lines), "savedAt": payload["savedAt"]}


@app.get("/v1/transcripts/{video_id}")
def load_transcript(video_id: str, http_request: Request = None) -> dict[str, Any]:
    """저장된 전사문. 없으면 404 — 앱이 그때 자기 기기에서 만든다."""
    _require_video_access(http_request, video_id)
    payload = store.get_json(_transcript_key(video_id))
    if payload is None:
        raise HTTPException(status_code=404, detail="no saved transcript")
    return payload


# ── 편집 완성본과 댓글은 백엔드로 이전됐다 ─────────────────────────────
#
# 완성본 MP4·메타·댓글을 이 서비스가 MinIO JSON으로 들고 있었더니, 권한을 매
# 요청 백엔드에 되묻고(왕복+60초 캐시), 보관 만료가 없어 편집본이 영구
# 보존되고, 댓글이 read-modify-write라 동시 작성이 유실되고, 작성자 이름이 앱
# 자가 신고라 위조 가능했다. 게다가 백그라운드 업로더는 세션이 없어 이 서비스의
# /v1 인증을 통과할 수 없었다(운영에서 401).
#
# 이제 백엔드가 원본 영상과 같은 videos 행(EDIT_OUTPUT) + video_comments로
# 관리한다: 업로드 예약 POST /api/videos/{id}/edits, 목록 GET
# /api/vaults/{id}/edits, 댓글 GET·POST /api/videos/{id}/comments, 재생은
# 원본과 같은 POST /api/videos/{id}/play-url.
#
# 이 서비스는 "무거운 미디어·AI 계산"만 한다 — 분석·추천·렌더·만화.


# ── 4컷 만화 (API-71·API-72의 내부 워커) ──────────────────────────────────
#
# 앱이 직접 부르지 않는다. Spring이 인증·금고 권한을 확인하고 원본 presigned
# URL을 붙여 이 라우트로 넘긴다. 그래도 이 모듈의 다른 라우트와 같은 검사를
# 붙여 둔다 — 게이트웨이를 우회해 직접 들어오면 로그인만으로 남의 영상을
# 만화로 만들 수 있기 때문이다(미들웨어는 토큰 서명만 본다).


class ComicScriptRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    video_url: str = Field(alias="videoUrl", min_length=1)
    """원본 presigned URL. ffmpeg가 그대로 읽는다 — 우리가 내려받지 않는다."""

    lines: list[dict[str, Any]] = Field(default_factory=list)
    """앱이 ML Kit으로 만든 자막. `{startMs, text}` 목록. 무발화면 빈 목록."""

    frame_count: int | None = Field(default=None, alias="frameCount", ge=1, le=comic.FRAME_LIMIT)


class ComicImageRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    cuts: list[dict[str, Any]]
    """사용자가 대사를 고친 4컷. 그림 프롬프트에는 beat·scene만 쓴다."""

    style: str = Field(default=comic.DEFAULT_STYLE)


def _comic_sheet_key(video_id: str) -> str:
    return f"comic/{video_id}/sheet.json"


def _comic_panel_key(video_id: str) -> str:
    return f"comic/{video_id}/panel.png"


def _comic_saved_key(video_id: str) -> str:
    """그림과 함께 남긴 구성·저장 시각. 그림이 있다는 증거로도 쓴다."""
    return f"comic/{video_id}/panel.json"


def _comic_script_key(video_id: str) -> str:
    return f"comic/{video_id}/script.json"


def _comic_frame_timeline(video_id: str) -> list[dict[str, Any]] | None:
    """만화가 프레임을 고를 점수 타임라인. 분석이 없으면 None.

    **왜 분석을 다시 돌리지 않나**: 편집(AI 자동 컷·줌)이 이미 같은 영상을 분석해
    `edit-analyses/{video_id}/*.json`에 남겨 두었다. 소리(yamnet·audio)와 영상
    (video·expression) 네 종이 다 있어야 타임라인을 만들 수 있고, 하나라도 없으면
    `_load_cached_analyses`가 None을 준다. 그때는 만화가 등분으로 되돌아간다 —
    분석을 아직 안 돌린 영상이라고 만화를 못 만들 이유는 없다.
    """
    try:
        analyses = _load_cached_analyses(video_id)
    except (BotoCoreError, ClientError, OSError):
        return None
    if analyses is None:
        return None
    try:
        return build_timeline(
            analyses["yamnet"], analyses["audio"], analyses.get("video")
        )
    except (KeyError, TypeError, ValueError):
        # 분석 파일이 예전 판이라 모양이 다를 수 있다. 만화를 막을 일은 아니다.
        return None


def _render_and_store_comic(
    video_id: str, cuts: list[dict[str, Any]], style: str | None
) -> bytes:
    """만화 한 장을 그려 MinIO에 남기고 그 바이트를 돌려준다.

    동기 경로(POST)와 백그라운드 작업이 함께 쓴다 — 그림을 만드는 방법이 두
    벌이면 한쪽만 고치는 일이 생긴다.
    """
    # 시트는 있으면 좋고 없으면 없는 대로 간다. MinIO가 죽었다고 그림까지
    # 못 만들 이유가 없다 — `get_json`은 ClientError만 잡아서 연결 오류
    # (BotoCoreError)는 그대로 올라온다.
    try:
        sheet = store.get_json(_comic_sheet_key(video_id)) or {}
    except (BotoCoreError, ClientError, OSError):
        sheet = {}

    png = comic.render_comic(
        cuts,
        characters=sheet.get("characters") or [],
        setting=str(sheet.get("setting") or ""),
        style=style,
    )

    # 저장은 최선 노력이다. 저장에 실패해도 방금 만든 그림을 버리지 않는다 —
    # 동기 경로는 응답으로 돌려주고, 백그라운드 경로는 아래에서 예외로 잡아
    # 상태에 남긴다.
    store.put_bytes(_comic_panel_key(video_id), png, "image/png")
    store.put(
        _comic_saved_key(video_id),
        {
            "videoId": video_id,
            "cuts": cuts,
            "style": style,
            "savedAt": datetime.now().astimezone().isoformat(),
        },
    )
    return png


def _render_comic_job(
    video_id: str, cuts: list[dict[str, Any]], style: str | None
) -> None:
    """백그라운드 작업자가 부르는 진입점. 그림 자체는 버리고 저장만 남긴다."""
    _render_and_store_comic(video_id, cuts, style)


comic_jobs = ComicJobManager(
    render=_render_comic_job,
    on_done=lambda job: backend_events.comic_ready(job.video_id, job.requested_by),
)


@app.post("/v1/comic/{video_id}/script")
def comic_script(
    video_id: str, request: ComicScriptRequest, http_request: Request = None
) -> dict[str, Any]:
    """1단계 — 프레임 4~6장 + 자막으로 4컷 구성을 짠다.

    인물·배경 시트는 응답에 담지 않고 MinIO에 남긴다. 앱 계약은 `cuts`뿐이고,
    시트는 2단계가 프롬프트를 조립할 재료다.
    """
    _require_video_access(http_request, video_id)
    try:
        script = comic.build_script(
            request.video_url,
            request.lines,
            count=request.frame_count or comic.FRAME_COUNT,
            timeline=_comic_frame_timeline(video_id),
        )
    except comic.ComicContractError as failure:
        raise HTTPException(status_code=422, detail=str(failure)) from failure
    except comic.ComicError as failure:
        raise HTTPException(status_code=502, detail=str(failure)) from failure

    try:
        store.put(
            _comic_sheet_key(video_id),
            {
                "characters": script["characters"],
                "setting": script["setting"],
                "savedAt": datetime.now().astimezone().isoformat(),
            },
        )
        # 구성도 남긴다. 이걸 저장하지 않으면 앱이 화면에 들어올 때마다 구성을
        # 처음부터 다시 받는다 — 뒤로 갔다 오면 사용자가 고친 대사가 사라지고
        # Gemini 호출료가 다시 든다. 실제로 그렇게 동작하고 있었다.
        store.put(
            _comic_script_key(video_id),
            {
                "cuts": script["cuts"],
                "savedAt": datetime.now().astimezone().isoformat(),
            },
        )
    except (BotoCoreError, ClientError, OSError):
        # 시트를 못 남겨도 구성은 돌려준다 — 2단계가 시트 없이 조립하면 품질만
        # 떨어지고, 여기서 502를 주면 이미 쓴 구성 호출값을 버리게 된다.
        pass

    return {"cuts": script["cuts"]}


@app.post("/v1/comic/{video_id}/image")
def comic_image(
    video_id: str, request: ComicImageRequest, http_request: Request = None
) -> dict[str, Any]:
    """2단계(동기) — 고친 구성으로 2x2 만화 한 장. 응답은 순수 base64 PNG다.

    `data:image/png;base64,` 접두어를 붙이면 앱의 `base64Decode`가 터진다.

    앱은 백그라운드 경로(PUT)를 쓴다. 이 경로는 화면을 벗어나지 않고 곧바로
    결과를 보려는 호출(재시도·도구)을 위해 남겨 둔다 — 그림 만드는 방법은
    `_render_and_store_comic` 한 곳이므로 결과는 양쪽이 같고 저장도 같이 된다.
    """
    _require_video_access(http_request, video_id)
    try:
        png = _render_and_store_comic(video_id, request.cuts, request.style)
    except comic.ComicContractError as failure:
        raise HTTPException(status_code=422, detail=str(failure)) from failure
    except comic.ComicError as failure:
        raise HTTPException(status_code=502, detail=str(failure)) from failure
    # 이 경로로 만든 만화도 알림을 남긴다. 알림 행이 "이 금고의 어떤 영상에
    # 만화가 있는가"의 기록이기도 해서(백엔드가 목록 배지에 쓴다), 한쪽 경로만
    # 알림을 보내면 동기로 만든 만화는 목록에서 배지가 빠진다.
    backend_events.comic_ready(video_id, _token_subject(http_request))
    return {"image": base64.b64encode(png).decode()}


@app.put("/v1/comic/{video_id}/image")
def comic_image_enqueue(
    video_id: str, request: ComicImageRequest, http_request: Request = None
) -> JSONResponse:
    """2단계(백그라운드) — 그림을 뒤에서 만든다. 202를 주고 곧 돌려보낸다.

    Gemini 이미지 호출이 수십 초라 화면을 붙잡아 둘 이유가 없다. 끝나면
    MinIO에 남고 백엔드 알림(COMIC_READY)이 나간다. 앱은 GET으로 상태를
    확인하거나 알림을 받고 추억 탭에서 다시 본다.
    """
    _require_video_access(http_request, video_id)
    try:
        job, position = comic_jobs.submit(
            video_id,
            request.cuts,
            request.style,
            requested_by=_token_subject(http_request),
        )
    except ComicQueueFull as failure:
        # 오래 기다린 끝에 실패하게 두지 않고 지금 거절한다.
        raise HTTPException(status_code=429, detail=str(failure)) from failure
    return JSONResponse(status_code=202, content=job.snapshot(position=position))


@app.get("/v1/comic/{video_id}/image")
def comic_image_status(
    video_id: str, http_request: Request = None
) -> dict[str, Any]:
    """만화 작업 상태와, 다 됐으면 그림을 받을 presigned URL.

    앱이 화면을 다시 열었을 때 이 하나로 "만드는 중 / 다 됨 / 실패"를 가른다.
    저장된 그림이 있으면 작업 기록이 사라진 뒤에도 done으로 답한다 — 서버가
    재시작해도 이미 만든 만화는 그대로 있다.
    """
    _require_video_access(http_request, video_id)
    tracked = comic_jobs.get(video_id)
    url = None
    try:
        saved = store.get_json(_comic_saved_key(video_id))
    except (BotoCoreError, ClientError, OSError):
        saved = None
    if saved is not None:
        url = store.presign_get(_comic_panel_key(video_id))

    # 저장해 둔 구성. 이것을 함께 주면 앱이 화면에 다시 들어올 때 구성을 새로
    # 받지 않는다 — 그 호출은 Gemini 과금이고, 새로 받으면 사용자가 고친 대사도
    # 서버 원문으로 덮인다. 그림을 아직 만들지 않은 영상에도 있을 수 있다.
    try:
        script = store.get_json(_comic_script_key(video_id))
    except (BotoCoreError, ClientError, OSError):
        script = None
    # 그림을 만들 때 보낸 구성이 가장 최신이다(사용자가 고친 대사가 들어 있다).
    cuts = (saved or {}).get("cuts") or (script or {}).get("cuts")

    if tracked is not None:
        job, position = tracked
        snapshot = job.snapshot(position=position)
        # 작업이 실패했더라도 예전에 만든 그림이 있으면 그것은 그대로 준다 —
        # 재시도가 실패했다고 어제 만든 만화를 감출 이유가 없다.
        snapshot["imageUrl"] = url
        snapshot["savedAt"] = (saved or {}).get("savedAt")
        snapshot["cuts"] = cuts
        return snapshot
    if saved is not None:
        return {
            "videoId": video_id,
            "status": "done",
            "error": None,
            "queuePosition": 0,
            "imageUrl": url,
            "savedAt": saved.get("savedAt"),
            "cuts": cuts,
        }
    return {
        "videoId": video_id,
        # 그림은 없지만 구성은 있을 수 있다. 그 경우도 status는 none이고, 앱은
        # cuts를 보고 구성 화면부터 다시 이어 간다.
        "status": "none",
        "error": None,
        "queuePosition": 0,
        "imageUrl": None,
        "savedAt": None,
        "cuts": cuts,
    }


@app.delete("/v1/comic/{video_id}", status_code=204)
def delete_comic(video_id: str, http_request: Request = None) -> Response:
    """만화를 통째로 버린다 — 그림, 구성, 인물·배경 시트까지.

    **왜 구성까지 지우나**: 구성만 남기면 앱이 상태를 물었을 때 `cuts`가 그대로
    와서, 지운 만화가 "그림 없는 만화"로 목록에 되살아난다. 지운다는 말은 그
    영상에 만화가 없던 상태로 되돌린다는 뜻이다.

    없는 것을 지우라고 해도 204다 — 목록을 보고 눌렀는데 그 사이 다른 가족이
    지웠다면 사용자가 원한 상태가 이미 이뤄진 것이다(초안 삭제와 같은 판단).
    """
    _require_video_access(http_request, video_id)
    if not comic_jobs.discard(video_id):
        raise HTTPException(
            status_code=409,
            detail="만화를 만드는 중입니다. 다 만든 뒤에 지울 수 있습니다.",
        )
    try:
        for key in (
            _comic_panel_key(video_id),
            _comic_saved_key(video_id),
            _comic_script_key(video_id),
            _comic_sheet_key(video_id),
        ):
            store.delete(key)
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 삭제 실패: {failure}") from failure
    return Response(status_code=204)
