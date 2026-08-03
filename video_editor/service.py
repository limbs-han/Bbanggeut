"""Local HTTP API that exposes the automatic edit recipe to the Flutter app."""

from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field

from .adaptive_cli import build_adaptive_recipe
from .analysis_jobs import ANALYSIS_KINDS, AnalysisJobManager, analysis_ready


FIXTURE_ROOT = Path(
    os.environ.get("EDITOR_FIXTURE_ROOT", Path(__file__).with_name("fixtures") / "analysis")
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


def build_fixture_recommendation(request: RecommendationRequest) -> dict[str, Any]:
    stem = _fixture_stem(request.captured_at)
    if stem is None:
        raise KeyError("no fixture matches capturedAt")
    preset = request.duration_preset or FIXTURE_PRESETS[stem]
    if preset not in {"auto", "short", "medium", "long"}:
        raise ValueError("durationPreset must be auto, short, medium, or long")
    recipe = build_adaptive_recipe(
        _read_analysis(stem, "yamnet"),
        _read_analysis(stem, "audio"),
        _read_analysis(stem, "video"),
        _read_analysis(stem, "expression"),
        duration_preset=preset,
        zoom_enabled=request.zoom_enabled,
    )
    recipe["videoId"] = request.video_id
    recipe["fixture"] = stem
    return recipe


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
store = RecipeStore()
jobs = AnalysisJobManager(
    save=lambda video_id, kind, payload: store.put(
        f"edit-analyses/{video_id}/{kind}.json", payload
    )
)


def _load_cached_analyses(video_id: str) -> dict[str, dict[str, Any]] | None:
    """MinIO에 저장된 4종 분석 결과. 하나라도 없으면 None."""
    analyses: dict[str, dict[str, Any]] = {}
    for kind in ANALYSIS_KINDS:
        payload = store.get_json(f"edit-analyses/{video_id}/{kind}.json")
        if payload is None:
            return None
        analyses[kind] = payload
    return analyses


@app.get("/health")
def health() -> dict[str, Any]:
    ready, reason = analysis_ready()
    return {
        "status": "ok",
        "fixtures": len(FIXTURE_PRESETS),
        "analysis": ready,
        "analysisUnavailableReason": reason,
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
    return recipe


@app.post("/v1/edit-recommendations")
def recommend(request: RecommendationRequest) -> dict[str, Any]:
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
    """원본 영상을 통째로 받아 백그라운드 분석을 시작한다.

    앱은 편집 진입 시 로컬에 이미 받아 둔 원본을 그대로 올린다(localhost라
    수 초). 202를 받으면 GET으로 상태를 폴링한다. 이미 분석돼 있으면 즉시
    done을 돌려준다.
    """
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
    data = await request.body()
    if not data:
        raise HTTPException(status_code=422, detail="empty body")
    upload_dir = Path(tempfile.gettempdir()) / "wj-edit-analysis"
    upload_dir.mkdir(parents=True, exist_ok=True)
    video_path = upload_dir / f"{video_id}.mp4"
    video_path.write_bytes(data)
    job = jobs.submit(video_id, video_path)
    return JSONResponse(status_code=202, content=job.snapshot())


@app.get("/v1/edit-analyses/{video_id}")
def analysis_status(video_id: str) -> dict[str, Any]:
    job = jobs.get(video_id)
    if job is not None:
        return job.snapshot()
    if _load_cached_analyses(video_id) is not None:
        return {"videoId": video_id, "status": "done", "progress": 1.0}
    return {"videoId": video_id, "status": "none", "progress": 0.0}


@app.put("/v1/edit-projects/{video_id}")
def save_project(video_id: str, request: ProjectSaveRequest) -> dict[str, Any]:
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
def list_projects() -> dict[str, Any]:
    """편집 중인(초안이 저장된) 영상 목록. 앱의 "이어서 편집"이 쓴다."""
    try:
        keys = store.list_keys("edit-projects/")
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 조회 실패: {failure}") from failure
    items = []
    for entry in keys:
        parts = entry["key"].split("/")
        if len(parts) != 3 or parts[2] != "latest.json":
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
def load_project(video_id: str) -> dict[str, Any]:
    """가장 최근 사용자 초안. 없으면 404 — 자동 추천은 recommend가 따로 만든다."""
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
def list_edited_videos() -> dict[str, Any]:
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
        if payload:
            items.append(payload)
    items.sort(key=lambda item: str(item.get("savedAt", "")), reverse=True)
    return {"items": items}


@app.get("/v1/edited-videos/{video_id}/file")
def edited_video_file(video_id: str) -> StreamingResponse:
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
def list_comments(video_id: str) -> dict[str, Any]:
    payload = store.get_json(f"edited-videos/{video_id}/comments.json")
    return payload or {"items": []}


@app.post("/v1/edited-videos/{video_id}/comments")
def add_comment(video_id: str, request: CommentRequest) -> dict[str, Any]:
    key = f"edited-videos/{video_id}/comments.json"
    payload = store.get_json(key) or {"items": []}
    comment = {
        "id": len(payload["items"]) + 1,
        "author": request.author.strip() or "가족",
        "text": request.text.strip(),
        "createdAt": datetime.now().astimezone().isoformat(),
    }
    payload["items"].append(comment)
    try:
        store.put(key, payload)
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 저장 실패: {failure}") from failure
    return comment
