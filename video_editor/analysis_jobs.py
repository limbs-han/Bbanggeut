"""임의 영상의 백그라운드 분석 작업 관리.

앱이 편집 진입 시 원본을 업로드하면 4단계 분석(음량→YAMNet→영상→표정)을
순서대로 돌리고, 앱은 상태를 폴링하다가 끝나면 추천을 다시 요청한다.
mediapipe 같은 무거운 의존성은 작업 스레드 안에서만 임포트한다 —
분석 의존성이 없는 환경에서도 서비스와 테스트는 그대로 돈다.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import threading
import urllib.request
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
_STAGE_DONE = {
    "download": 0.03,
    "audio": 0.05,
    "yamnet": 0.09,
    "video": 0.35,
    "expression": 1.0,
}


def analysis_ready() -> tuple[bool, str | None]:
    """지금 분석을 돌릴 수 있는가 — 모델 파일과 분석 의존성 확인."""
    for path in (YAMNET_MODEL, FACE_MODEL, LANDMARKER_MODEL):
        if not path.is_file():
            return False, f"모델 파일이 없습니다: {path}"
    for module in ("mediapipe", "av", "numpy"):
        if importlib.util.find_spec(module) is None:
            return False, f"분석 의존성이 없습니다: {module} (requirements-analysis.txt)"
    return True, None


# 차례를 기다릴 수 있는 작업 수. 넘치면 즉시 거절한다.
#
# **왜 상한이 필요한가**: 작업자가 하나뿐인데 요청을 전부 받아 두면, 뒤쪽 작업은
# 차례가 올 때까지 몇 분을 기다린다. 그 사이 앱이 준 원본 presigned URL(백엔드
# 기본 5분)이 만료되어, 오래 기다린 끝에 내려받기부터 실패한다.
#
# **왜 4인가**: 실측 처리 시간(2분 내외 영상 약 16초, 긴 영상 약 51초)에서 왔다.
# 51초짜리가 넷이면 마지막 작업은 약 3분 26초에 시작하므로 5분 안에 들어온다.
# 서명 URL 수명을 늘려 해결하지 않는 이유는, 그것이 보안 트레이드오프인 데다
# 줄이 길어지면 어차피 같은 곳에서 다시 터지기 때문이다.
MAX_WAITING = max(1, int(os.environ.get("EDITOR_ANALYSIS_MAX_QUEUE", "4")))


class AnalysisQueueFull(Exception):
    """대기 줄이 꽉 찼다. 호출자는 429로 돌려주고 나중에 다시 오게 한다."""


@dataclass
class AnalysisJob:
    video_id: str
    status: str = "running"  # running | done | failed
    stage: str = "audio"
    progress: float = 0.0
    error: str | None = None
    # 분석을 요청한 사용자(앱 토큰의 sub). 완료 알림의 수신자다.
    requested_by: str | None = None
    started_at: str = field(
        default_factory=lambda: datetime.now().astimezone().isoformat()
    )

    def snapshot(self, *, position: int = 0) -> dict[str, Any]:
        return {
            "videoId": self.video_id,
            "status": self.status,
            "stage": self.stage,
            "progress": round(self.progress, 3),
            "error": self.error,
            "startedAt": self.started_at,
            # 앞에 몇 개가 있는가. 0이면 지금 처리 중이거나 이미 끝났다.
            # 얼마나 기다려야 하는지 모르면 사용자는 그냥 다시 누른다.
            "queuePosition": position,
        }


class AnalysisJobManager:
    """영상당 하나의 분석 작업. 작업자 한 명이 순서대로 처리한다.

    로컬 데모 규모라 동시 분석은 없다 — 큐에 쌓이면 차례대로 돈다.
    결과 저장은 호출자가 준 save 콜백(MinIO 등)에 맡긴다.

    **줄은 [MAX_WAITING]으로 막는다.** 예전에는 상한이 없어 요청을 전부
    수락했고, 뒤쪽 작업은 차례가 올 때까지 기다리는 동안 원본 presigned URL이
    만료되어 내려받기부터 실패했다 — 오래 기다린 끝에 실패하는 것이 가장 나쁘다.
    """

    def __init__(
        self,
        save: Callable[[str, str, dict[str, Any]], None],
        on_done: Callable[[AnalysisJob], None] | None = None,
        on_start: Callable[[AnalysisJob], None] | None = None,
        on_progress: Callable[[AnalysisJob], None] | None = None,
        on_failed: Callable[[AnalysisJob], None] | None = None,
        *,
        max_waiting: int = MAX_WAITING,
    ) -> None:
        self._max_waiting = max(1, max_waiting)
        self._jobs: dict[str, AnalysisJob] = {}
        self._lock = threading.Lock()
        self._executor = ThreadPoolExecutor(max_workers=1)
        self._save = save
        self._on_done = on_done
        self._on_start = on_start
        self._on_progress = on_progress
        self._on_failed = on_failed

    @staticmethod
    def _report(
        hook: Callable[[AnalysisJob], None] | None, job: AnalysisJob
    ) -> None:
        """상태 보고는 최선 노력이다. 백엔드가 잠깐 죽었다고 분석을 멈추지 않는다."""
        if hook is None:
            return
        try:
            hook(job)
        except Exception:  # noqa: BLE001 — 보고 실패는 분석과 무관하다
            pass

    def get(self, video_id: str) -> AnalysisJob | None:
        with self._lock:
            return self._jobs.get(video_id)

    def _waiting_ids(self) -> list[str]:
        """아직 끝나지 않은 작업을 들어온 순서대로. 락을 쥔 채로만 부른다.

        dict가 삽입 순서를 지키므로 이것이 곧 처리 순서다 — 작업자가 하나뿐이라
        submit한 차례대로 돈다.
        """
        return [
            video_id
            for video_id, job in self._jobs.items()
            if job.status == "running"
        ]

    def position(self, video_id: str) -> int:
        """앞에 몇 개가 있는가. 0이면 지금 처리 중이거나 이미 끝났다."""
        with self._lock:
            waiting = self._waiting_ids()
        return waiting.index(video_id) if video_id in waiting else 0

    def submit(
        self,
        video_id: str,
        video_path: Path,
        *,
        source_url: str | None = None,
        requested_by: str | None = None,
    ) -> AnalysisJob:
        """분석 작업 등록. source_url이 있으면 작업자가 그 주소에서 원본을
        video_path로 먼저 내려받는다(실서버 — 원본이 이미 MinIO에 있어서
        폰이 다시 올릴 필요가 없다). 없으면 video_path에 이미 업로드돼
        있어야 한다."""
        with self._lock:
            existing = self._jobs.get(video_id)
            if existing is not None and existing.status == "running":
                return existing
            # 지금 도는 것 하나는 상한에서 뺀다 — 세는 것은 "기다리는 줄"이다.
            if max(0, len(self._waiting_ids()) - 1) >= self._max_waiting:
                raise AnalysisQueueFull(
                    f"분석 대기 줄이 가득 찼습니다({self._max_waiting}건). "
                    "잠시 뒤에 다시 시도해 주세요."
                )
            job = AnalysisJob(
                video_id=video_id,
                stage="download" if source_url else "audio",
                requested_by=requested_by,
            )
            self._jobs[video_id] = job
        # 락 밖에서 보고한다 — 백엔드 호출은 네트워크라, 락을 쥔 채로 부르면
        # 그동안 상태를 묻는 요청이 전부 멈춘다.
        self._report(self._on_start, job)
        self._executor.submit(self._run, job, video_path, source_url)
        return job

    def _run(
        self, job: AnalysisJob, video_path: Path, source_url: str | None
    ) -> None:
        # 일시 오류(내려받기 끊김, 디코더 개별 실패)를 한 번은 자체 복구한다.
        # 두 번째도 실패하면 원인을 상태로 남기고 앱 폴백에 맡긴다.
        try:
            for attempt in (1, 2):
                try:
                    self._run_once(job, video_path, source_url)
                    job.status = "done"
                    self._report(self._on_done, job)
                    return
                except Exception as failure:  # noqa: BLE001 — 상태로 보고한다
                    if attempt == 2:
                        job.status = "failed"
                        job.error = f"{type(failure).__name__}: {failure}"
                        # 실패도 알려야 한다. 안 알리면 백엔드가 RUNNING을 든
                        # 채로 남아 앱이 영원히 "분석 중"을 본다.
                        self._report(self._on_failed, job)
                    else:
                        job.stage = "download" if source_url else "audio"
                        job.progress = 0.0
        finally:
            try:
                video_path.unlink(missing_ok=True)
            except OSError:
                pass

    def _run_once(
        self, job: AnalysisJob, video_path: Path, source_url: str | None
    ) -> None:
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
                # 마지막 단계는 알리지 않는다 — 곧바로 완료 보고가 뒤따르므로
                # 진행률 1.0 직전 값을 한 번 더 보내는 왕복이 된다.
                self._report(self._on_progress, job)

        if source_url is not None:
            with (
                urllib.request.urlopen(source_url, timeout=30) as response,
                open(video_path, "wb") as sink,
            ):
                shutil.copyfileobj(response, sink, length=1 << 20)
            finish_stage("download", "audio")

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
