"""백엔드에 사용자 토큰을 그대로 전달해 영상 접근 권한을 판정한다.

editor-api는 금고(가족) 구성원 정보를 모른다. 대신 백엔드의
`GET /api/videos/{videoId}`를 사용자 토큰으로 호출하면 백엔드가
구성원 여부는 물론 세션 상태(로그아웃 즉시 무효화 포함)까지 판정한다.
결과는 토큰×영상 단위로 짧게 캐시해 백엔드를 두드리는 횟수를 줄인다.

`EDITOR_BACKEND_URL`이 비어 있으면 검사를 통째로 끈다 — adb reverse
루프백 전용 로컬 개발을 위한 것이다.
"""

from __future__ import annotations

import hashlib
import os
import threading
import time
import urllib.error
import urllib.request

BACKEND_URL = (os.environ.get("EDITOR_BACKEND_URL") or "").rstrip("/") or None

_CACHE_TTL_SECONDS = 60.0
_CACHE_MAX_ENTRIES = 2048
_cache: dict[tuple[str, str], tuple[float, bool]] = {}
_lock = threading.Lock()


def enabled() -> bool:
    return BACKEND_URL is not None


def _token_key(authorization: str) -> str:
    return hashlib.sha256(authorization.encode()).hexdigest()[:16]


def can_access_video(authorization: str | None, video_id: str) -> bool:
    """이 토큰의 사용자가 이 영상을 볼 수 있는가.

    백엔드가 2xx면 허용, 401/403/404면 거부. 백엔드가 죽어 판정할 수
    없을 때도 거부한다 — 편집 데이터가 잠기는 쪽이 새는 쪽보다 낫다.
    """
    if BACKEND_URL is None:
        return True
    if not authorization:
        return False
    key = (_token_key(authorization), video_id)
    now = time.monotonic()
    with _lock:
        hit = _cache.get(key)
        if hit is not None and hit[0] > now:
            return hit[1]
    request = urllib.request.Request(
        f"{BACKEND_URL}/api/videos/{video_id}",
        headers={"Authorization": authorization, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            allowed = 200 <= response.status < 300
    except (urllib.error.HTTPError, OSError):
        allowed = False
    with _lock:
        if len(_cache) >= _CACHE_MAX_ENTRIES:
            _cache.clear()
        _cache[key] = (now + _CACHE_TTL_SECONDS, allowed)
    return allowed
