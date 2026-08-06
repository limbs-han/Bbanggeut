"""분석 완료·새 댓글을 백엔드 알림(알림센터+FCM)으로 승격한다.

editor-api는 백엔드와 같은 HS256 키(EDITOR_JWT_SECRET)를 가지므로,
새 시크릿 배포 없이 iss=wj-editor 서비스 토큰을 만들어
`POST /api/editor/events`를 호출한다. 알림은 최선 노력이다 —
실패해도 편집 기능 자체는 계속돼야 하므로 경고 로그만 남긴다.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.request
from datetime import datetime, timedelta, timezone
from typing import Any

import jwt

from .backend_access import BACKEND_URL

_log = logging.getLogger(__name__)


def _service_token(secret: str) -> str:
    now = datetime.now(timezone.utc)
    return jwt.encode(
        {
            "iss": "wj-editor",
            "typ": "editor-event",
            "sub": "editor-api",
            "iat": now,
            "exp": now + timedelta(seconds=60),
        },
        secret,
        algorithm="HS256",
    )


def _notify(event: dict[str, Any]) -> None:
    secret = os.environ.get("EDITOR_JWT_SECRET") or None
    if BACKEND_URL is None or secret is None:
        return  # 로컬 개발 — 백엔드 연동이 꺼져 있다
    try:
        request = urllib.request.Request(
            f"{BACKEND_URL}/api/editor/events",
            method="POST",
            data=json.dumps(event).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {_service_token(secret)}",
            },
        )
        with urllib.request.urlopen(request, timeout=5):
            pass
    except Exception:  # noqa: BLE001 — 알림 실패가 편집을 막으면 안 된다
        _log.warning("백엔드 알림 발신 실패: %s", event.get("type"), exc_info=True)


def analysis_started(video_id: str, stage: str, user_id: str | None) -> None:
    """분석을 시작했다 — 백엔드가 상태를 들고 앱에 '분석 중'을 보여 준다.

    **왜 user_id가 없어도 보내나**: 알림과 달리 이것은 상태다. 받는 사람이 없어도
    "이 영상은 지금 분석 중"이라는 사실은 남아야 하고, 그래야 다른 가족이 같은
    영상을 열었을 때도 분석 중임을 본다.
    """
    _notify(
        {
            "type": "ANALYSIS_STARTED",
            "videoId": video_id,
            "userId": user_id,
            "stage": stage,
        }
    )


def analysis_progress(video_id: str, stage: str, progress: float) -> None:
    """단계가 넘어갔다. 알림은 만들지 않고 상태만 올린다."""
    _notify(
        {
            "type": "ANALYSIS_PROGRESS",
            "videoId": video_id,
            "stage": stage,
            "progress": round(float(progress), 3),
        }
    )


def analysis_failed(video_id: str, reason: str, user_id: str | None) -> None:
    """분석이 실패했다. 사유를 남겨야 앱이 영원히 '분석 중'을 보지 않는다."""
    _notify(
        {
            "type": "ANALYSIS_FAILED",
            "videoId": video_id,
            "userId": user_id,
            "body": reason[:500],
        }
    )


def analysis_ready(video_id: str, user_id: str | None) -> None:
    """분석이 끝났다. 상태를 남기고, 청한 사람이 있으면 알림도 보낸다.

    user_id가 없어도 보낸다 — 알림은 백엔드가 건너뛰지만 상태는 남아야 한다.
    """
    _notify({"type": "ANALYSIS_READY", "videoId": video_id, "userId": user_id})


def comic_ready(video_id: str, user_id: str | None) -> None:
    """4컷 만화가 다 그려졌다 — 요청한 사람에게만 알린다."""
    if not user_id:
        return
    _notify({"type": "COMIC_READY", "videoId": video_id, "userId": user_id})


def comment_added(
    video_id: str, user_id: str | None, comment_id: Any, body: str
) -> None:
    if not user_id:
        return
    _notify(
        {
            "type": "COMMENT_ADDED",
            "videoId": video_id,
            "userId": user_id,
            "commentId": str(comment_id),
            "body": body[:200],
        }
    )
