"""Local HTTP API that exposes the automatic edit recipe to the Flutter app."""

from __future__ import annotations

import base64
import json
import math
import os
from datetime import datetime
from pathlib import Path
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field

from . import comic
from .adaptive_cli import build_adaptive_recipe


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
    face_tracks = _face_tracks(expression)
    recipe["faceTracks"] = face_tracks
    # 하위 호환: 옛 앱은 한 줄짜리 faceTrack만 읽는다. 가장 오래 잡힌
    # 사람의 궤적을 준다 — 최강 표정을 오가던 예전 초점보다 안정적이다.
    recipe["faceTrack"] = (
        face_tracks[0]["samples"] if face_tracks else _face_track(expression)
    )
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


app = FastAPI(title="William James Local Video Editor", version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)
store = RecipeStore()


@app.get("/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "fixtures": len(FIXTURE_PRESETS)}


@app.get("/v1/fixtures")
def fixtures() -> dict[str, Any]:
    return {
        "items": [
            {"stem": stem, "durationPreset": preset}
            for stem, preset in FIXTURE_PRESETS.items()
        ]
    }


@app.post("/v1/edit-recommendations")
def recommend(request: RecommendationRequest) -> dict[str, Any]:
    try:
        recipe = build_fixture_recommendation(request)
    except (KeyError, FileNotFoundError) as failure:
        raise HTTPException(status_code=404, detail=str(failure)) from failure
    except ValueError as failure:
        raise HTTPException(status_code=422, detail=str(failure)) from failure
    object_key = f"edit-projects/{request.video_id}/auto-v1.json"
    try:
        store.put(object_key, recipe)
    except (BotoCoreError, ClientError, OSError) as failure:
        raise HTTPException(status_code=503, detail=f"MinIO 저장 실패: {failure}") from failure
    return {"recipe": recipe, "storedObjectKey": object_key}


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


# ── 4컷 만화 (API-71·API-72의 내부 워커) ──────────────────────────────────
#
# 앱이 직접 부르지 않는다. Spring이 인증·권한을 확인하고 presigned URL을 붙여
# 이 라우트로 넘긴다 — 그래서 여기에는 JWT 검증이 없고, 외부에 노출하지 않는다.


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


@app.post("/v1/comic/{video_id}/script")
def comic_script(video_id: str, request: ComicScriptRequest) -> dict[str, Any]:
    """1단계 — 프레임 4~6장 + 자막으로 4컷 구성을 짠다.

    인물·배경 시트는 응답에 담지 않고 MinIO에 남긴다. 앱 계약은 `cuts`뿐이고,
    시트는 2단계가 프롬프트를 조립할 재료다.
    """
    try:
        script = comic.build_script(
            request.video_url,
            request.lines,
            count=request.frame_count or comic.FRAME_COUNT,
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
    except (BotoCoreError, ClientError, OSError):
        # 시트를 못 남겨도 구성은 돌려준다 — 2단계가 시트 없이 조립하면 품질만
        # 떨어지고, 여기서 502를 주면 이미 쓴 구성 호출값을 버리게 된다.
        pass

    return {"cuts": script["cuts"]}


@app.post("/v1/comic/{video_id}/image")
def comic_image(video_id: str, request: ComicImageRequest) -> dict[str, Any]:
    """2단계 — 고친 구성으로 2x2 만화 한 장. 응답은 순수 base64 PNG다.

    `data:image/png;base64,` 접두어를 붙이면 앱의 `base64Decode`가 터진다.
    """
    # 시트는 있으면 좋고 없으면 없는 대로 간다. MinIO가 죽었다고 그림까지
    # 못 만들 이유가 없다 — `get_json`은 ClientError만 잡아서 연결 오류
    # (BotoCoreError)는 그대로 올라온다.
    try:
        sheet = store.get_json(_comic_sheet_key(video_id)) or {}
    except (BotoCoreError, ClientError, OSError):
        sheet = {}

    try:
        png = comic.render_comic(
            request.cuts,
            characters=sheet.get("characters") or [],
            setting=str(sheet.get("setting") or ""),
            style=request.style,
        )
    except comic.ComicContractError as failure:
        raise HTTPException(status_code=422, detail=str(failure)) from failure
    except comic.ComicError as failure:
        raise HTTPException(status_code=502, detail=str(failure)) from failure
    return {"image": base64.b64encode(png).decode()}
