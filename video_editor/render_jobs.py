"""서버 렌더링 작업 — 컷·줌 recipe를 FFmpeg로 만들어 편집본으로 올린다.

앱 렌더링(Media3)을 대체하지 않는 선택 경로다: 자막·스티커 같은 앱 전용
오버레이가 없는 프로젝트(컷 하나 + 줌)는 레시피(JSON 몇 KB)만 보내면
서버가 원본(presigned URL)에서 직접 만든다 — 폰이 완성본 MP4를 LTE로
올리는 시간이 통째로 사라진다. 오버레이가 있는 프로젝트는 지금처럼
앱이 만들어 올린다.
"""

from __future__ import annotations

import shutil
import threading
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

# 단계가 끝난 시점의 누적 진행률(대략치 — 렌더 시간은 구간 길이에 비례).
_STAGE_DONE = {"download": 0.25, "render": 0.9, "publish": 1.0}


@dataclass
class RenderJob:
    video_id: str
    status: str = "running"  # running | done | failed
    stage: str = "download"
    progress: float = 0.0
    error: str | None = None
    requested_by: str | None = None
    started_at: str = field(
        default_factory=lambda: datetime.now().astimezone().isoformat()
    )

    def snapshot(self) -> dict[str, Any]:
        return {
            "videoId": self.video_id,
            "status": self.status,
            "stage": self.stage,
            "progress": round(self.progress, 3),
            "error": self.error,
            "startedAt": self.started_at,
        }


class RenderJobManager:
    """영상당 하나의 렌더 작업. 분석과 같은 이유로 작업자 한 명이 순차 처리."""

    def __init__(self, publish: Callable[[str, Path, dict[str, Any]], None]) -> None:
        self._jobs: dict[str, RenderJob] = {}
        self._lock = threading.Lock()
        self._executor = ThreadPoolExecutor(max_workers=1)
        # publish(video_id, 완성본 경로, meta) — MinIO 저장은 호출자 몫.
        self._publish = publish

    def get(self, video_id: str) -> RenderJob | None:
        with self._lock:
            return self._jobs.get(video_id)

    def submit(
        self,
        video_id: str,
        work_dir: Path,
        *,
        source_url: str,
        recipe: dict[str, Any],
        meta: dict[str, Any],
        requested_by: str | None = None,
    ) -> RenderJob:
        with self._lock:
            existing = self._jobs.get(video_id)
            if existing is not None and existing.status == "running":
                return existing
            job = RenderJob(video_id=video_id, requested_by=requested_by)
            self._jobs[video_id] = job
        self._executor.submit(self._run, job, work_dir, source_url, recipe, meta)
        return job

    def _run(
        self,
        job: RenderJob,
        work_dir: Path,
        source_url: str,
        recipe: dict[str, Any],
        meta: dict[str, Any],
    ) -> None:
        from .render_video import render_recipe

        work_dir.mkdir(parents=True, exist_ok=True)
        source_path = work_dir / f"{job.video_id}.source.mp4"
        output_path = work_dir / f"{job.video_id}.edited.mp4"
        try:
            with (
                urllib.request.urlopen(source_url, timeout=30) as response,
                open(source_path, "wb") as sink,
            ):
                shutil.copyfileobj(response, sink, length=1 << 20)
            job.progress = _STAGE_DONE["download"]
            job.stage = "render"

            render_recipe(source_path, recipe, output_path)
            job.progress = _STAGE_DONE["render"]
            job.stage = "publish"

            self._publish(job.video_id, output_path, meta)
            job.progress = _STAGE_DONE["publish"]
            job.status = "done"
        except Exception as failure:  # noqa: BLE001 — 실패 원인을 상태로 보여 준다
            job.status = "failed"
            job.error = f"{type(failure).__name__}: {failure}"
        finally:
            for path in (source_path, output_path):
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    pass
