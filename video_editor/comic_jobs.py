"""4컷 만화 렌더링을 백그라운드로 돌린다.

만화 2단계(그림 생성)는 Gemini 이미지 호출이라 수십 초가 걸린다. 응답으로만
돌려주던 동안에는 사용자가 화면을 벗어나면 그 시간이 통째로 버려졌다 —
앱이 요청을 끊고, 서버는 만든 그림을 아무 데도 남기지 않았다.

그래서 세 가지를 바꾼다.
  1. 요청을 받으면 곧바로 202를 주고 작업자가 뒤에서 그린다.
  2. 결과 PNG를 MinIO에 남긴다(`comic/{video_id}/panel.png`).
  3. 끝나면 백엔드 알림으로 승격한다(COMIC_READY).

1단계(구성)는 그대로 동기다. 사용자가 대사를 고쳐야 다음으로 갈 수 있으니
기다리는 것이 맞다.

**분석 작업에서 배운 것**: `AnalysisJobManager`는 큐 상한이 없어 요청을 전부
수락했다. 워커가 하나뿐인데 상한이 없으면 뒤쪽 요청은 오래 기다린 끝에
실패하거나, 사용자가 기다리는 줄이 얼마나 긴지도 모른다. 여기서는 상한을
두고 넘치면 즉시 거절하며, 대기 순번을 상태에 담아 준다.
"""

from __future__ import annotations

import threading
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Callable


class ComicQueueFull(Exception):
    """대기 줄이 꽉 찼다. 호출자는 429로 돌려주고 나중에 다시 오게 한다."""


@dataclass
class ComicJob:
    video_id: str
    status: str = "queued"  # queued | running | done | failed
    error: str | None = None
    requested_by: str | None = None
    queued_at: str = field(
        default_factory=lambda: datetime.now().astimezone().isoformat()
    )

    def snapshot(self, *, position: int = 0) -> dict[str, Any]:
        return {
            "videoId": self.video_id,
            "status": self.status,
            "error": self.error,
            "queuedAt": self.queued_at,
            # 대기 순번. 0이면 지금 그리는 중이거나 이미 끝났다.
            "queuePosition": position,
        }


class ComicJobManager:
    """영상당 하나의 만화 작업. 작업자 한 명이 순서대로 그린다.

    Gemini 호출을 여러 개 동시에 던지면 요금과 속도 제한이 함께 튄다 —
    직렬이 의도다. 대신 줄 길이를 상한으로 막고 순번을 알려 준다.
    """

    def __init__(
        self,
        render: Callable[[str, list[dict[str, Any]], str | None], None],
        on_done: Callable[[ComicJob], None] | None = None,
        *,
        max_queue: int = 8,
    ) -> None:
        self._render = render
        self._on_done = on_done
        self._max_queue = max_queue
        self._lock = threading.Lock()
        self._jobs: dict[str, ComicJob] = {}
        self._waiting: deque[str] = deque()
        # 아직 그리지 않은 작업의 재료. 작업자가 꺼내 갈 때 지운다.
        self._pending: dict[str, tuple[list[dict[str, Any]], str | None]] = {}
        self._worker: threading.Thread | None = None

    def get(self, video_id: str) -> tuple[ComicJob, int] | None:
        """작업과 대기 순번. 없으면 None."""
        with self._lock:
            job = self._jobs.get(video_id)
            if job is None:
                return None
            position = (
                self._waiting.index(video_id) + 1
                if video_id in self._waiting
                else 0
            )
            return job, position

    def discard(self, video_id: str) -> bool:
        """작업 기록을 지운다. 지웠으면 True, 그리는 중이라 못 지웠으면 False.

        **왜 그리는 중이면 거절하나**: 기록만 지워도 작업자 스레드는 계속 그린다.
        끝나면 `panel.png`를 다시 쓰므로, 지운 만화가 잠시 뒤 혼자 되살아난다.
        스레드를 중간에 세울 방법이 없으니 끝나기를 기다리게 하는 것이 맞다.
        """
        with self._lock:
            job = self._jobs.get(video_id)
            if job is not None and job.status in ("queued", "running"):
                return False
            self._jobs.pop(video_id, None)
            self._pending.pop(video_id, None)
            return True

    def submit(
        self,
        video_id: str,
        cuts: list[dict[str, Any]],
        style: str | None,
        requested_by: str | None,
    ) -> tuple[ComicJob, int]:
        with self._lock:
            existing = self._jobs.get(video_id)
            if existing is not None and existing.status in ("queued", "running"):
                position = (
                    self._waiting.index(video_id) + 1
                    if video_id in self._waiting
                    else 0
                )
                return existing, position
            if len(self._waiting) >= self._max_queue:
                raise ComicQueueFull(
                    f"만화 대기 줄이 가득 찼습니다({self._max_queue}건). "
                    "잠시 뒤에 다시 시도해 주세요."
                )
            job = ComicJob(video_id=video_id, requested_by=requested_by)
            self._jobs[video_id] = job
            self._waiting.append(video_id)
            self._pending[video_id] = (cuts, style)
            position = len(self._waiting)
            self._ensure_worker()
            return job, position

    def _ensure_worker(self) -> None:
        """작업자 하나를 살려 둔다. 락을 쥔 채로만 부른다."""
        if self._worker is not None and self._worker.is_alive():
            return
        self._worker = threading.Thread(
            target=self._run_loop, name="comic-worker", daemon=True
        )
        self._worker.start()

    def _run_loop(self) -> None:
        while True:
            with self._lock:
                if not self._waiting:
                    self._worker = None
                    return
                video_id = self._waiting.popleft()
                job = self._jobs[video_id]
                cuts, style = self._pending.pop(video_id, ([], None))
                job.status = "running"
            try:
                self._render(video_id, cuts, style)
                job.status = "done"
                if self._on_done is not None:
                    try:
                        self._on_done(job)
                    except Exception:  # noqa: BLE001 — 알림 실패는 무시
                        pass
            except Exception as failure:  # noqa: BLE001 — 상태로 보고한다
                job.status = "failed"
                job.error = f"{type(failure).__name__}: {failure}"
