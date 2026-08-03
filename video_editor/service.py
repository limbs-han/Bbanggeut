"""Local HTTP API that exposes the automatic edit recipe to the Flutter app."""

from __future__ import annotations

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
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field

from . import backend_access, backend_events
from .adaptive_cli import build_adaptive_recipe
from .analysis_jobs import ANALYSIS_KINDS, AnalysisJobManager, analysis_ready
from .render_jobs import RenderJobManager


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

    def put_bytes(self, key: str, data: bytes, content_type: str) -> None:
        self.ensure_bucket()
        self.client.put_object(
            Bucket=self.bucket, Key=key, Body=data, ContentType=content_type
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
)


def _publish_edited_video(
    video_id: str, output_path: Path, meta: dict[str, Any]
) -> None:
    """렌더 완성본을 앱 업로드 경로와 같은 위치·형식으로 저장한다."""
    data = output_path.read_bytes()
    meta = {**meta, "sizeBytes": len(data)}
    store.put_bytes(f"edited-videos/{video_id}/edited.mp4", data, "video/mp4")
    store.put(f"edited-videos/{video_id}/meta.json", meta)


renders = RenderJobManager(publish=_publish_edited_video)


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
        return JSONResponse(status_code=202, content=running.snapshot())
    if _load_cached_analyses(video_id) is not None:
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
        job = jobs.submit(
            video_id,
            video_path,
            source_url=source_url,
            requested_by=_token_subject(request),
        )
    else:
        data = await request.body()
        if not data:
            raise HTTPException(status_code=422, detail="empty body")
        video_path.write_bytes(data)
        job = jobs.submit(video_id, video_path, requested_by=_token_subject(request))
    return JSONResponse(status_code=202, content=job.snapshot())


@app.get("/v1/edit-analyses/{video_id}")
def analysis_status(video_id: str, http_request: Request = None) -> dict[str, Any]:
    _require_video_access(http_request, video_id)
    job = jobs.get(video_id)
    if job is not None:
        return job.snapshot()
    if _load_cached_analyses(video_id) is not None:
        return {"videoId": video_id, "status": "done", "progress": 1.0}
    return {"videoId": video_id, "status": "none", "progress": 0.0}


class RenderRequest(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    source_url: str = Field(alias="sourceUrl", min_length=1)
    # 컷·줌 recipe(render_video.render_recipe 계약): cut{startMs,endMs,
    # durationMs}, zoomSegments[], zoomEnabled. 원본 시각(ms) 기준.
    recipe: dict[str, Any]
    title: str = Field(default="", max_length=200)
    captured_at: str = Field(default="", alias="capturedAt")


@app.post("/v1/edit-renders/{video_id}")
def request_render(
    video_id: str, request: RenderRequest, http_request: Request = None
) -> JSONResponse:
    """컷·줌만 있는 프로젝트의 완성본을 서버가 만든다.

    앱은 레시피(몇 KB)만 보내고, 서버가 원본을 presigned URL로 받아
    FFmpeg로 렌더링해 편집본 자리에 올린다 — 폰이 완성본을 업로드하는
    시간이 사라진다. 자막·스티커가 있는 프로젝트는 앱이 만들어 올린다.
    """
    _require_video_access(http_request, video_id)
    running = renders.get(video_id)
    if running is not None and running.status == "running":
        return JSONResponse(status_code=202, content=running.snapshot())
    if not source_url_allowed(request.source_url):
        raise HTTPException(
            status_code=422,
            detail="sourceUrl은 허용된 호스트의 https 주소여야 합니다",
        )
    cut = request.recipe.get("cut")
    if not isinstance(cut, dict) or "startMs" not in cut or "endMs" not in cut:
        raise HTTPException(status_code=422, detail="recipe.cut이 필요합니다")
    cut.setdefault("durationMs", int(cut["endMs"]) - int(cut["startMs"]))
    if int(cut["durationMs"]) <= 0:
        raise HTTPException(status_code=422, detail="컷 길이가 0 이하입니다")
    meta = {
        "videoId": video_id,
        "objectKey": f"edited-videos/{video_id}/edited.mp4",
        "savedAt": datetime.now().astimezone().isoformat(),
        "title": request.title,
        "durationMs": int(cut["durationMs"]),
        "capturedAt": request.captured_at,
        "renderedBy": "server",
    }
    work_dir = Path(tempfile.gettempdir()) / "wj-edit-render"
    job = renders.submit(
        video_id,
        work_dir,
        source_url=request.source_url,
        recipe=request.recipe,
        meta=meta,
        requested_by=_token_subject(http_request),
    )
    return JSONResponse(status_code=202, content=job.snapshot())


@app.get("/v1/edit-renders/{video_id}")
def render_status(video_id: str, http_request: Request = None) -> dict[str, Any]:
    _require_video_access(http_request, video_id)
    job = renders.get(video_id)
    if job is not None:
        return job.snapshot()
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


@app.put("/v1/edited-videos/{video_id}")
async def upload_edited_video(video_id: str, request: Request) -> dict[str, Any]:
    """렌더링된 편집 영상을 통째로 받아 MinIO에 저장한다.

    데모 규모(숏폼 수십 MB)를 넘는 대용량은 다루지 않는다 — 그건 백엔드의
    presigned 업로드 몫이다.
    """
    _require_video_access(request, video_id)
    data = await request.body()
    if not data:
        raise HTTPException(status_code=422, detail="empty body")
    saved_at = datetime.now().astimezone().isoformat()
    object_key = f"edited-videos/{video_id}/edited.mp4"
    meta = {
        "videoId": video_id,
        "objectKey": object_key,
        "sizeBytes": len(data),
        "savedAt": saved_at,
        "title": request.query_params.get("title", ""),
        "durationMs": int(request.query_params.get("durationMs", "0") or 0),
        # 원본이 감지된(촬영된) 시각. 캘린더는 편집한 날이 아니라 이 날짜에
        # 편집본을 표시한다.
        "capturedAt": request.query_params.get("capturedAt", ""),
    }
    try:
        store.put_bytes(object_key, data, "video/mp4")
        store.put(f"edited-videos/{video_id}/meta.json", meta)
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 저장 실패: {failure}") from failure
    return meta


@app.get("/v1/edited-videos")
def list_edited_videos(http_request: Request = None) -> dict[str, Any]:
    """편집 완료 영상 목록 — 캘린더와 추억 화면이 쓴다."""
    try:
        keys = store.list_keys("edited-videos/")
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 조회 실패: {failure}") from failure
    items = []
    for entry in keys:
        if not entry["key"].endswith("/meta.json"):
            continue
        payload = store.get_json(entry["key"])
        if not payload:
            continue
        video_id = str(payload.get("videoId", ""))
        if http_request is not None and not _accessible(http_request, video_id):
            continue
        items.append(payload)
    items.sort(key=lambda item: str(item.get("savedAt", "")), reverse=True)
    return {"items": items}


@app.get("/v1/edited-videos/{video_id}/play-url")
def edited_video_play_url(
    video_id: str, http_request: Request = None
) -> dict[str, Any]:
    """편집본 재생용 presigned URL(1시간).

    재생 스트리밍을 editor-api가 물고 있지 않도록 MinIO가 직접 낸다.
    공개 endpoint가 설정돼 있지 않으면 url이 null — 앱은 /file로 폴백한다.
    """
    _require_video_access(http_request, video_id)
    if store.get_json(f"edited-videos/{video_id}/meta.json") is None:
        raise HTTPException(status_code=404, detail="no edited video")
    try:
        url = store.presign_get(f"edited-videos/{video_id}/edited.mp4")
    except (BotoCoreError, ClientError) as failure:
        raise HTTPException(status_code=503, detail=f"서명 실패: {failure}") from failure
    return {"url": url}


@app.get("/v1/edited-videos/{video_id}/file")
def edited_video_file(video_id: str, http_request: Request = None) -> StreamingResponse:
    _require_video_access(http_request, video_id)
    stream = store.open_stream(f"edited-videos/{video_id}/edited.mp4")
    if stream is None:
        raise HTTPException(status_code=404, detail="no edited video")
    body, length = stream
    return StreamingResponse(
        body.iter_chunks(chunk_size=1 << 20),
        media_type="video/mp4",
        headers={"Content-Length": str(length)},
    )


class CommentRequest(BaseModel):
    author: str = Field(default="가족", max_length=40)
    text: str = Field(min_length=1, max_length=500)


@app.get("/v1/edited-videos/{video_id}/comments")
def list_comments(video_id: str, http_request: Request = None) -> dict[str, Any]:
    _require_video_access(http_request, video_id)
    payload = store.get_json(f"edited-videos/{video_id}/comments.json")
    return payload or {"items": []}


@app.post("/v1/edited-videos/{video_id}/comments")
def add_comment(
    video_id: str, request: CommentRequest, http_request: Request = None
) -> dict[str, Any]:
    _require_video_access(http_request, video_id)
    key = f"edited-videos/{video_id}/comments.json"
    payload = store.get_json(key) or {"items": []}
    comment = {
        "id": len(payload["items"]) + 1,
        "author": request.author.strip() or "가족",
        # 표시 이름은 앱 자가 신고지만, 토큰의 사용자 UUID를 함께 기록해
        # 누가 썼는지는 검증 가능하게 남긴다. 이름까지 서버가 박으려면
        # 백엔드에 프로필 조회 API(GET /api/auth/me)가 생겨야 한다.
        "authorUserId": _token_subject(http_request),
        "text": request.text.strip(),
        "createdAt": datetime.now().astimezone().isoformat(),
    }
    payload["items"].append(comment)
    try:
        store.put(key, payload)
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 저장 실패: {failure}") from failure
    # 가족에게 알림센터+FCM으로 새 댓글을 알린다(최선 노력).
    backend_events.comment_added(
        video_id, comment["authorUserId"], comment["id"], comment["text"]
    )
    return comment
