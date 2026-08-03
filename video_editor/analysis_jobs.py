"""임의 영상의 백그라운드 분석 작업 관리.

앱이 편집 진입 시 원본을 업로드하면 4단계 분석(음량→YAMNet→영상→표정)을
순서대로 돌리고, 앱은 상태를 폴링하다가 끝나면 추천을 다시 요청한다.
mediapipe 같은 무거운 의존성은 작업 스레드 안에서만 임포트한다 —
분석 의존성이 없는 환경에서도 서비스와 테스트는 그대로 돈다.
"""

from __future__ import annotations

import importlib.util
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

_MODEL_ROOT = Path(
    os.environ.get("EDITOR_MODEL_ROOT", Path(__file__).with_name("models"))
)
YAMNET_MODEL = Path(os.environ.get("EDITOR_YAMNET_MODEL", _MODEL_ROOT / "yamnet.tflite"))
FACE_MODEL = Path(
    os.environ.get("EDITOR_FACE_MODEL", _MODEL_ROOT / "blaze_face_full_range.tflite")
)
LANDMARKER_MODEL = Path(
    os.environ.get("EDITOR_LANDMARKER_MODEL", _MODEL_ROOT / "face_landmarker.task")
)

ANALYSIS_KINDS = ("yamnet", "audio", "video", "expression")

# 단계가 끝난 시점의 누적 진행률. 비율은 검증 영상 5개(2분 내외)의 실측
# 처리 시간(음량 0.2초, YAMNet 0.7초, 영상 4.5초, 표정 11초)에서 왔다.
_STAGE_DONE = {"audio": 0.02, "yamnet": 0.06, "video": 0.33, "expression": 1.0}


def analysis_ready() -> tuple[bool, str | None]:
    """지금 분석을 돌릴 수 있는가 — 모델 파일과 분석 의존성 확인."""
    for path in (YAMNET_MODEL, FACE_MODEL, LANDMARKER_MODEL):
        if not path.is_file():
            return False, f"모델 파일이 없습니다: {path}"
    for module in ("mediapipe", "av", "numpy"):
        if importlib.util.find_spec(module) is None:
            return False, f"분석 의존성이 없습니다: {module} (requirements-analysis.txt)"
    return True, None


@dataclass
class AnalysisJob:
    video_id: str
    status: str = "running"  # running | done | failed
    stage: str = "audio"
    progress: float = 0.0
    error: str | None = None
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


class AnalysisJobManager:
    """영상당 하나의 분석 작업. 작업자 한 명이 순서대로 처리한다.

    로컬 데모 규모라 동시 분석은 없다 — 큐에 쌓이면 차례대로 돈다.
    결과 저장은 호출자가 준 save 콜백(MinIO 등)에 맡긴다.
    """

    def __init__(self, save: Callable[[str, str, dict[str, Any]], None]) -> None:
        self._jobs: dict[str, AnalysisJob] = {}
        self._lock = threading.Lock()
        self._executor = ThreadPoolExecutor(max_workers=1)
        self._save = save

    def get(self, video_id: str) -> AnalysisJob | None:
        with self._lock:
            return self._jobs.get(video_id)

    def submit(self, video_id: str, video_path: Path) -> AnalysisJob:
        with self._lock:
            existing = self._jobs.get(video_id)
            if existing is not None and existing.status == "running":
                return existing
            job = AnalysisJob(video_id=video_id)
            self._jobs[video_id] = job
        self._executor.submit(self._run, job, video_path)
        return job

    def _run(self, job: AnalysisJob, video_path: Path) -> None:
        try:
            from . import (
                audio_features,
                expression_analysis,
                video_features,
                yamnet_analysis,
            )

            def finish_stage(stage: str, next_stage: str | None) -> None:
                job.progress = _STAGE_DONE[stage]
                if next_stage is not None:
                    job.stage = next_stage

            self._save(job.video_id, "audio", audio_features.analyze_video(video_path))
            finish_stage("audio", "yamnet")
            self._save(
                job.video_id,
                "yamnet",
                yamnet_analysis.classify_video(video_path, YAMNET_MODEL),
            )
            finish_stage("yamnet", "video")
            self._save(
                job.video_id,
                "video",
                video_features.analyze_video(video_path, FACE_MODEL),
            )
            finish_stage("video", "expression")
            self._save(
                job.video_id,
                "expression",
                expression_analysis.analyze_expressions(video_path, LANDMARKER_MODEL),
            )
            finish_stage("expression", None)
            job.status = "done"
        except Exception as failure:  # noqa: BLE001 — 실패 원인을 상태로 보여 준다
            job.status = "failed"
            job.error = f"{type(failure).__name__}: {failure}"
        finally:
            try:
                video_path.unlink(missing_ok=True)
            except OSError:
                pass
