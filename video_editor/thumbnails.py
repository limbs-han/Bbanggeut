"""영상 목록에 쓸 작은 미리보기 그림을 서버에서 만든다.

**왜 서버가 만드나**: 예전에는 앱이 만들었다. `VideoThumbnail.thumbnailFile`에
원본의 presigned URL을 넘기면 안드로이드 미디어 스택(stagefright)이 그 URL을
열어 목표 지점까지 range 요청으로 받아 내려가며 프레임 하나를 디코딩한다.
실측(2026-08-06, 운영 nginx 로그): 영상 299개에 stagefright 요청 1,732건,
**1,943MB**. 썸네일 한 장에 6.5MB, range 요청 5.8회다. 같은 기간 실제 재생
(ExoPlayer)이 1,604MB였으니 **보는 것보다 목록 그리는 데 더 많이 받았다.**

`maxWidth: 720` 같은 값으로는 줄지 않는다. 그 값은 **디코딩이 끝난 뒤** 결과
JPEG을 줄이는 것이라 네트워크에는 아무 영향이 없다. 줄일 것은 전송량 자체이고,
그러려면 프레임을 뽑는 일을 원본 옆(서버)에서 해야 한다. 서버는 MinIO와 같은
도커 네트워크에 있어 같은 6.5MB를 훨씬 싸게 읽는다.

**왜 가운데인가**: 감지 클립은 이벤트 시각 앞뒤로 `preSeconds`·`postSeconds`씩
잘라 만든다(둘 다 기본 60초). 즉 **웃은 순간이 클립의 정확히 가운데**다 —
운영 데이터에서 LAUGHTER 269건 중 183건이 120초±3초였다. 별도 분석 없이
가운데를 집는 것이 곧 "웃은 시점"이고, 길이가 다른 클립(사람이 올린 영상 등)
에서도 가운데는 무난한 한 장이다.
"""

from __future__ import annotations

import os

from .comic import ComicError, _run


# 목록 칸은 92x68dp다. 3배 화면에서도 276px이라 480이면 넉넉하고, 상세 화면에
# 크게 걸 그림이 아니다. 폭을 키워 봐야 앱이 [cacheWidth]로 다시 줄인다.
THUMBNAIL_WIDTH = int(os.environ.get("THUMBNAIL_WIDTH", "480"))

# ffmpeg -q:v(2~31, 낮을수록 좋다). 5는 목록 크기에서 열화가 보이지 않는 선이다.
THUMBNAIL_QUALITY = os.environ.get("THUMBNAIL_QUALITY", "5")


def thumbnail_offset_seconds(duration_ms: int | None) -> float:
    """어느 지점에서 뽑을까. 가운데 — 감지 클립에서는 그것이 이벤트 시각이다.

    길이를 모르면 앞쪽 한 지점으로 물러선다. 0초를 피하는 이유는 클립 첫 프레임이
    검은 화면이거나 흔들려서 목록에 검은 칸이 깔리기 때문이다.
    """
    if duration_ms is None or duration_ms <= 0:
        return 1.0
    middle = duration_ms / 2000
    # 아주 짧은 클립은 가운데가 0.5초도 안 된다. 그래도 첫 프레임보다는 낫다.
    return max(0.1, middle)


def extract_thumbnail(
    video_url: str,
    duration_ms: int | None = None,
    *,
    width: int = THUMBNAIL_WIDTH,
    quality: str = THUMBNAIL_QUALITY,
) -> bytes:
    """원본에서 미리보기 JPEG 한 장. presigned URL을 그대로 먹인다.

    `-ss`를 `-i` 앞에 둔다. 뒤에 두면 ffmpeg가 0초부터 디코딩하며 내려가서,
    2분짜리 영상의 가운데를 잡으려고 앞 1분을 통째로 받는다. 앞에 두면 컨테이너
    색인을 보고 그 지점으로 건너뛴다 — 원본이 faststart로 만들어져 있어(기기
    업로더가 `-movflags +faststart`를 쓴다) 색인이 파일 앞머리에 있다.
    """
    jpeg = _run(
        [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-ss",
            f"{thumbnail_offset_seconds(duration_ms):.3f}",
            "-i",
            video_url,
            "-frames:v",
            "1",
            "-vf",
            f"scale={width}:-2",
            "-f",
            "image2pipe",
            "-vcodec",
            "mjpeg",
            "-q:v",
            quality,
            "pipe:1",
        ]
    )
    if not jpeg:
        raise ComicError("영상에서 미리보기 프레임을 뽑지 못했습니다.")
    return jpeg
