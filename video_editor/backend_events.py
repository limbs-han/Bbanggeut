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


def analysis_ready(video_id: str, user_id: str | None) -> None:
    if not user_id:
        return
    _notify({"type": "ANALYSIS_READY", "videoId": video_id, "userId": user_id})


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
