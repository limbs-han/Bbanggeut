"""4컷 만화 두 단계 — 프레임·대사로 구성을 짜고(1단계), 그 구성으로 그림을 받는다(2단계).

**왜 두 단계인가**: 그림 생성은 호출마다 돈이 든다(실측 약 400크레딧). 구성을 먼저
사람에게 보여 대사를 고친 뒤 그리면, 엉뚱한 구성에 그림값을 쓰지 않는다.

**왜 프레임을 함께 넣나**: 대사만 주면 모델이 장면을 상상한다. 프레임을 보면 누가
있고 무슨 일이 있었는지 보고 쓴다. 다만 실측(2026-08-03, GMS): 이미지 한 장이
**크기와 무관하게 입력 1,089토큰**이라 몇 장이든 공짜가 아니다. 그래서 4~6장으로
묶는다 — 영상을 초당 1장으로 통째로 넣으면 13만 토큰이 된다.

**모델이 둘인 이유**: `gemini-3.5-flash`는 이미지를 만들지 못한다. 실측으로 확인했다 —
`responseModalities`에 IMAGE를 넣고 "빨간 원을 그려라"고 했더니 그림 대신 HTML/CSS와
Python 코드를 글로 써 줬다. 그림은 `gemini-2.5-flash-image`가 낸다.

이 모듈은 HTTP 라우트를 모른다. `service.py`가 라우트를 붙이고 오류를 상태 코드로
옮긴다 — 그래야 네트워크 없이 조립 규칙을 테스트할 수 있다.
"""

from __future__ import annotations

import base64
import json
import os
import re
import struct
import subprocess
from collections.abc import Iterable, Mapping, Sequence
from typing import Any

import httpx


GMS_BASE = os.environ.get(
    "GMS_BASE_URL",
    "https://gms.ssafy.io/gmsapi/generativelanguage.googleapis.com/v1beta",
)
SCRIPT_MODEL = os.environ.get("COMIC_SCRIPT_MODEL", "gemini-3.5-flash")
IMAGE_MODEL = os.environ.get("COMIC_IMAGE_MODEL", "gemini-2.5-flash-image")

# 앱은 180초까지 기다린다. 서버가 먼저 끊어 502를 줘야 앱이 살아 있는 응답을
# 자르지 않는다 — 그래서 150초다.
TIMEOUT_SECONDS = float(os.environ.get("COMIC_TIMEOUT_SECONDS", "150"))

CUT_COUNT = 4

# GMS 프록시가 요청 본문 약 100KB에서 끊는다. 넘기면 `contents is not
# specified`(400)로 거부된다 — 프레임 내용이 아니라 **크기** 문제다.
#
# 개수로 상한을 잡으면 안 된다. 장당 크기가 영상 내용에 따라 2배 이상 달라진다 —
# 실측(2026-08-04, 320폭 q8 JPEG 기준으로 환산): 어떤 영상은 장당 base64 17KB,
# 다른 영상은 40KB(512폭 q5)였다. 그래서 개수 대신 **바이트 예산**으로 자른다.
FRAME_LIMIT = 5
FRAME_COUNT = max(1, min(FRAME_LIMIT, int(os.environ.get("COMIC_FRAME_COUNT", "5"))))

# 프레임 base64 합계 상한. 100KB 제한에서 프롬프트 글(지시문+자막)이 쓸 몫을
# 남겨 둔다. 자막이 긴 영상도 있으니 넉넉히 비운다.
FRAME_BASE64_BUDGET = 72_000

# 프레임 해상도는 토큰 수와 무관하다(장당 약 1,100토큰 고정 — 1장 1,766 대 5장
# 6,166으로 실측). 즉 **줄여도 모델이 보는 값은 그대로고 요청 크기만 준다.**
# 실측(2026-08-04, 같은 영상): 512폭 q5는 장당 40KB로 5장이 203KB(거부),
# 320폭 q8은 장당 14KB로 5장이 71KB(통과). 그래서 작게 보낸다.
FRAME_WIDTH = 320
FRAME_QUALITY = "8"

DEFAULT_STYLE = "soft webtoon"

# 컷 번호 → 격자 위치. 읽는 순서와 같다. 앱이 자막을 이 순서로 얹으므로
# 어긋나면 3컷 대사가 1컷에 붙는다.
PANEL_POSITIONS = ("top-left", "top-right", "bottom-left", "bottom-right")


class ComicError(RuntimeError):
    """만화를 만들지 못했다 — 우리 잘못이거나 GMS 잘못. 라우트가 502로 옮긴다."""


class ComicContractError(ValueError):
    """모델이 약속한 모양을 어겼다 — 라우트가 422로 옮긴다."""


SCRIPT_PROMPT = """당신은 가족 홈캠 영상을 4컷 만화로 각색하는 작가다.
아래 프레임(영상에서 시간순으로 뽑았다)과 대사 기록을 보고 JSON만 출력해라.

규칙
- cuts는 정확히 4개다. 기·승·전·결 순서로 놓는다.
- scene은 **한 순간의 정지 화면** 묘사다. 동작의 연속이나 시간 경과를 쓰지 마라.
- scene에서 사람은 characters의 label로만 부른다.
- scene에 소리·의성어를 쓰지 마라. 쓰면 그림에 글자가 박힌다.
- dialogue는 대사 기록에서 **그대로** 가져온다. 지어내지 마라. 없는 컷은 null.
- characters는 프레임에 실제로 보이는 사람만 넣는다. appearance는 만화가가 이 글만
  보고 그릴 수 있게 구체적으로 쓴다(나이대·머리 모양과 색·안경 유무·옷 색과 종류).
  특정인을 알아볼 수 있는 묘사는 쓰지 마라.
- setting은 공간 한 곳을 쓴다(장소·가구·조명·시간대)."""

# 이미지 모델에 넣는 금지 블록. 앞쪽 지시가 더 강하게 먹히므로 조립 순서상 맨 뒤에
# 두되, 문장은 단정형으로 쓴다.
# 금지 규칙에서 "자막"·"카메라 UI" 같은 단어를 쓰면 안 된다. 부정 지시도 그
# 물건을 모델에게 떠올리게 한다 — "아래 1/4을 단순하게 두라(앱이 자막을 얹는다)"
# 라고 적었더니 모델이 네 칸 아래에 자막 띠와 아이콘을 직접 그렸다(2026-08-04
# 실측). 포괄 금지 한 줄 + 긍정 구도 지시로만 말한다.
STRICT_RULES = """STRICT RULES:
- Pure illustration only. The image must contain no writing of any kind:
  no letters, no numbers, no logos, no icons, no symbols.
- No speech bubbles, no thought bubbles. Show sound or impact with motion
  lines and posture only.
- Place people and action in the upper two thirds of each panel. The bottom
  of each panel is plain scene background such as floor or furniture."""

_SCRIPT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "characters": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "appearance": {"type": "string"},
                },
                "required": ["label", "appearance"],
            },
        },
        "setting": {"type": "string"},
        "cuts": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "beat": {"type": "string"},
                    "scene": {"type": "string"},
                    "dialogue": {"type": "string", "nullable": True},
                },
                "required": ["beat", "scene"],
            },
        },
    },
    "required": ["characters", "setting", "cuts"],
}


# ── GMS 호출 ────────────────────────────────────────────────────────────────


def _gms(model: str, body: Mapping[str, Any]) -> dict[str, Any]:
    """GMS 프록시로 generateContent 한 번. 키는 환경변수에서만 읽는다.

    **`urllib`을 쓰지 마라.** 같은 요청을 표준 `urllib.request`로 보내면 응답
    본문의 **앞부분이 잘린 채** 온다 — 실측(컨테이너 안, 2026-08-03)으로 같은
    호출에서 urllib은 79바이트를 `modelVersion": ...`부터 받았고 httpx는
    1,036바이트를 `{"candidates": ...`부터 온전히 받았다. 프록시가 내려주는
    응답을 urllib이 잘못 읽는다.
    """
    key = os.environ.get("GMS_KEY")
    if not key:
        raise ComicError("GMS_KEY 환경변수가 없습니다.")
    try:
        response = httpx.post(
            f"{GMS_BASE}/models/{model}:generateContent",
            json=dict(body),
            headers={"Content-Type": "application/json", "x-goog-api-key": key},
            timeout=TIMEOUT_SECONDS,
        )
    except httpx.HTTPError as failure:
        raise ComicError(f"GMS 호출 실패: {failure}") from failure
    if response.status_code >= 400:
        raise ComicError(f"GMS {response.status_code}: {response.text.strip()[:400]}")
    try:
        payload = response.json()
    except json.JSONDecodeError as failure:
        raise ComicError(f"GMS 응답이 JSON이 아닙니다: {response.text[:200]}") from failure
    # 크레딧은 여기서만 실측할 수 있다. 응답에 담아 앱까지 보내지 않고 로그로만
    # 남긴다 — 프레임 수를 조정할 때 이 숫자를 보고 정한다.
    usage = usage_summary(payload)
    print(f"[comic] {model} tokens={usage}", flush=True)
    return payload


# ── 프레임 뽑기 ────────────────────────────────────────────────────────────


def _run(command: Sequence[str], stdin: bytes | None = None) -> bytes:
    try:
        done = subprocess.run(  # noqa: S603 - 인자를 리스트로 넘겨 셸을 거치지 않는다
            list(command),
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except FileNotFoundError as failure:
        raise ComicError(
            f"{command[0]}를 찾을 수 없습니다. 컨테이너에 ffmpeg를 설치해야 합니다."
        ) from failure
    except subprocess.CalledProcessError as failure:
        message = failure.stderr.decode("utf-8", "replace").strip()[-300:]
        raise ComicError(f"{command[0]} 실패: {message}") from failure
    return done.stdout


def _run_capturing_stderr(
    command: Sequence[str], stdin: bytes | None = None
) -> tuple[bytes, str]:
    """[_run]과 같지만 stderr도 돌려준다.

    `cropdetect` 같은 필터는 결과를 stdout이 아니라 로그로 남긴다 — 그 값을
    읽어야 하는 호출만 이것을 쓴다.
    """
    try:
        done = subprocess.run(  # noqa: S603 - 인자를 리스트로 넘겨 셸을 거치지 않는다
            list(command),
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except FileNotFoundError as failure:
        raise ComicError(
            f"{command[0]}를 찾을 수 없습니다. 컨테이너에 ffmpeg를 설치해야 합니다."
        ) from failure
    except subprocess.CalledProcessError as failure:
        message = failure.stderr.decode("utf-8", "replace").strip()[-300:]
        raise ComicError(f"{command[0]} 실패: {message}") from failure
    return done.stdout, done.stderr.decode("utf-8", "replace")


def video_duration_seconds(video_url: str) -> float:
    raw = _run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=nw=1:nk=1",
            video_url,
        ]
    )
    try:
        return float(raw.decode().strip())
    except ValueError as failure:
        raise ComicError("영상 길이를 읽지 못했습니다.") from failure


def frame_timestamps(duration: float, count: int = FRAME_COUNT) -> list[float]:
    """구간을 count등분해 각 구간의 **가운데**를 고른다.

    0초와 끝을 피하는 이유: 클립 앞뒤는 검은 화면이거나 흔들려서, 거기서 뽑은
    프레임은 인물·공간 정보를 거의 주지 못한 채 1,089토큰을 쓴다.
    """
    if duration <= 0 or count <= 0:
        return []
    return [duration * (index + 0.5) / count for index in range(count)]


# 만화 칸으로 쓸 프레임의 점수. 편집이 쓰는 eventScore를 그대로 쓰지 않는 이유는
# 그 값이 소리 중심이기 때문이다 — 화면 밖에서 크게 웃는 순간은 자동 컷에는 맞지만
# 만화 칸으로는 빈 방 사진이 된다. 얼굴이 보이고 흐리지 않은 쪽으로 기울인다.
_PANEL_VISUAL_FLOOR = 0.55


def panel_score(window: Mapping[str, Any]) -> float:
    """구간 하나가 만화 칸으로 얼마나 쓸 만한가. 0~1."""
    features = window.get("features") or {}
    visual = (
        0.5 * float(features.get("facePresence", 0.0))
        + 0.3 * float(features.get("faceProminence", 0.0))
        + 0.2 * float(features.get("visualQuality", 0.0))
    )
    event = float(window.get("eventScore", 0.0))
    return event * (_PANEL_VISUAL_FLOOR + (1 - _PANEL_VISUAL_FLOOR) * min(1.0, visual))


def _window_center_seconds(window: Mapping[str, Any]) -> float | None:
    try:
        start = int(window["startMs"])
        end = int(window["endMs"])
    except (KeyError, TypeError, ValueError):
        return None
    return (start + end) / 2000


def panel_timestamps(
    timeline: Sequence[Mapping[str, Any]],
    duration: float,
    count: int = FRAME_COUNT,
) -> list[float]:
    """점수 타임라인에서 만화 칸으로 쓸 시각을 고른다. 시간 순으로 돌려준다.

    **왜 등분이 아닌가**: [frame_timestamps]는 영상을 count등분해 가운데를 뽑는다.
    내용을 전혀 보지 않아서, 웃음이 3초에 터져도 6·18·30초를 가져간다. 편집(자동
    컷·줌)은 이미 같은 분석에서 나온 타임라인으로 순간을 고르고 있는데 만화만
    쓰지 않았다.

    **왜 간격을 두는가**: 점수만 보면 상위 다섯이 같은 2초 안에 몰린다. 웃음
    한 번이 여러 구간에 걸치기 때문이다. 그러면 네 칸이 거의 같은 그림이 되어
    기승전결이 사라진다. 최소 간격을 두고 고른 뒤 시간 순으로 되돌린다.

    타임라인이 없거나 쓸 구간이 없으면 등분으로 되돌아간다 — 분석을 아직 돌리지
    않은 영상도 만화는 만들 수 있어야 한다.
    """
    if duration <= 0 or count <= 0:
        return []
    # 앞뒤 가장자리는 검은 화면이거나 흔들린다. visualQuality가 걸러 주기는 하나
    # 영상 분석 없이 소리만으로 만든 타임라인에는 그 값이 없다.
    # 경계를 포함하지 않는다. 구간이 1초씩이면 첫 구간의 가운데가 정확히 0.5초라,
    # 여기서 등호를 허용하면 걸러 내려던 첫 프레임이 그대로 통과한다.
    margin = min(0.5, duration * 0.05)
    windows = [
        (at, panel_score(window))
        for window in timeline
        if (at := _window_center_seconds(window)) is not None
        and margin < at < duration - margin
    ]
    if not windows:
        return frame_timestamps(duration, count)

    # 점수가 같으면 앞선 순간을 고른다 — 같은 입력에 같은 만화가 나와야 한다.
    ranked = sorted(windows, key=lambda pair: (-pair[1], pair[0]))
    min_gap = duration / (count * 2)
    picked: list[float] = []
    for at, _ in ranked:
        if all(abs(at - other) >= min_gap for other in picked):
            picked.append(at)
        if len(picked) == count:
            break
    # 짧은 영상은 간격을 지키다 개수를 못 채운다. 남은 자리는 점수 순으로 메운다 —
    # 비슷한 칸이라도 프레임이 적은 것보다 낫다(인물표가 흔들린다).
    if len(picked) < count:
        for at, _ in ranked:
            if at not in picked:
                picked.append(at)
            if len(picked) == count:
                break
    picked.sort()
    return picked


def fit_frame_budget(
    frames: Sequence[bytes], budget: int = FRAME_BASE64_BUDGET
) -> list[bytes]:
    """base64 합계가 예산을 넘지 않도록 뒤 프레임을 버린다.

    한 장은 예산을 넘겨도 남긴다 — 프레임이 하나도 없으면 인물표를 못 뽑아
    칸마다 다른 사람이 그려진다. 크게 실패하는 대신 품질만 떨어뜨린다.
    """
    kept: list[bytes] = []
    used = 0
    for frame in frames:
        encoded = (len(frame) + 2) // 3 * 4
        if kept and used + encoded > budget:
            break
        kept.append(frame)
        used += encoded
    return kept


def extract_frames(
    video_url: str,
    count: int = FRAME_COUNT,
    timeline: Sequence[Mapping[str, Any]] | None = None,
) -> list[bytes]:
    """원본에서 JPEG 프레임 몇 장을 뽑는다. presigned URL을 그대로 먹인다.

    개수는 [FRAME_LIMIT]으로, 크기는 [FRAME_BASE64_BUDGET]으로 자른다. 둘 다
    필요한 이유는 GMS가 **요청 크기**에서 끊는데 장당 크기가 영상에 따라 배로
    달라지기 때문이다 — 개수만 막으면 어떤 영상에서는 그대로 400이 된다.

    `timeline`(편집 분석이 남긴 점수 타임라인)을 주면 무슨 일이 일어난 순간에서
    뽑는다. 없으면 등분한다.
    """
    frames: list[bytes] = []
    count = max(1, min(FRAME_LIMIT, count))
    duration = video_duration_seconds(video_url)
    moments = (
        frame_timestamps(duration, count)
        if not timeline
        else panel_timestamps(timeline, duration, count)
    )
    for at in moments:
        # -ss를 -i 앞에 두면 빠른 탐색이다. 뒤에 두면 앞부터 디코딩한다.
        jpeg = _run(
            [
                "ffmpeg",
                "-nostdin",
                "-loglevel",
                "error",
                "-ss",
                f"{at:.3f}",
                "-i",
                video_url,
                "-frames:v",
                "1",
                "-vf",
                f"scale={FRAME_WIDTH}:-2",
                "-f",
                "image2pipe",
                "-vcodec",
                "mjpeg",
                "-q:v",
                FRAME_QUALITY,
                "pipe:1",
            ]
        )
        if jpeg:
            frames.append(jpeg)
    if not frames:
        raise ComicError("영상에서 프레임을 뽑지 못했습니다.")
    return fit_frame_budget(frames)


# ── 1단계: 구성 ────────────────────────────────────────────────────────────


def lines_to_text(lines: Iterable[Mapping[str, Any]]) -> str:
    """자막 줄을 프롬프트용 한 덩이로. 빈 글은 버리고 시각을 붙인다.

    시각을 주는 이유: 모델이 프레임(시간순)과 대사를 맞춰 컷 순서를 잡는다.
    """
    parts: list[str] = []
    for line in lines:
        text = str(line.get("text", "")).strip()
        if not text:
            continue
        start = int(line.get("startMs", 0) or 0)
        parts.append(f"[{start / 1000:.1f}s] {text}")
    return "\n".join(parts)


def _first_text(payload: Mapping[str, Any]) -> str:
    candidates = payload.get("candidates") or []
    if not candidates:
        raise ComicContractError(f"응답에 candidates가 없습니다: {sorted(payload)}")
    parts = (candidates[0].get("content") or {}).get("parts") or []
    text = "".join(str(part["text"]) for part in parts if part.get("text"))
    if not text.strip():
        raise ComicContractError("응답에 글이 없습니다.")
    return text


def _clean_characters(raw: Any) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    for entry in raw if isinstance(raw, list) else []:
        if not isinstance(entry, Mapping):
            continue
        label = str(entry.get("label", "")).strip()
        appearance = str(entry.get("appearance", "")).strip()
        if label and appearance:
            out.append({"label": label, "appearance": appearance})
    return out


def parse_script(payload: Mapping[str, Any]) -> dict[str, Any]:
    """모델 응답 → `{cuts, characters, setting}`. 계약 위반은 던진다.

    컷이 4개가 아니면 조용히 넘기지 않는다 — 그림이 2x2 격자 한 장이고 앱이 각
    칸에 자막을 얹으므로, 컷 수가 다르면 얹을 칸이 안 맞는다.
    """
    text = _first_text(payload)
    try:
        data = json.loads(text)
    except json.JSONDecodeError as failure:
        raise ComicContractError(f"JSON이 아닙니다: {text[:200]}") from failure
    if not isinstance(data, Mapping):
        raise ComicContractError("최상위가 객체가 아닙니다.")

    raw_cuts = data.get("cuts")
    if not isinstance(raw_cuts, list) or len(raw_cuts) != CUT_COUNT:
        got = len(raw_cuts) if isinstance(raw_cuts, list) else raw_cuts
        raise ComicContractError(f"만화는 {CUT_COUNT}컷이어야 합니다 (받은 것: {got}).")

    cuts: list[dict[str, Any]] = []
    for index, entry in enumerate(raw_cuts):
        if not isinstance(entry, Mapping):
            raise ComicContractError(f"{index + 1}컷이 객체가 아닙니다.")
        beat = str(entry.get("beat", "")).strip()
        scene = str(entry.get("scene", "")).strip()
        if not beat or not scene:
            raise ComicContractError(f"{index + 1}컷에 beat나 scene이 없습니다.")
        dialogue = entry.get("dialogue")
        dialogue = str(dialogue).strip() if isinstance(dialogue, str) else ""
        # 빈 문자열은 null로 본다 — 앱이 빈 자막 띠를 그리지 않게.
        cuts.append(
            {"beat": beat, "scene": scene, "dialogue": dialogue or None}
        )

    return {
        "cuts": cuts,
        "characters": _clean_characters(data.get("characters")),
        "setting": str(data.get("setting", "")).strip(),
    }


def build_script(
    video_url: str,
    lines: Iterable[Mapping[str, Any]],
    *,
    count: int = FRAME_COUNT,
    frames: Sequence[bytes] | None = None,
    timeline: Sequence[Mapping[str, Any]] | None = None,
) -> dict[str, Any]:
    """프레임 + 자막 → 4컷 구성과 인물·배경 시트.

    `frames`를 주면 추출을 건너뛴다 — 테스트와 재시도용이다.
    `timeline`은 편집 분석이 남긴 점수 타임라인이다 — 주면 그 영상에서 실제로
    무슨 일이 일어난 순간을 프레임으로 쓴다.
    """
    images = (
        list(frames)
        if frames is not None
        else extract_frames(video_url, count, timeline)
    )
    spoken = lines_to_text(lines) or "(대사 기록이 없다 — 프레임만 보고 짜라.)"
    parts: list[dict[str, Any]] = [
        {"text": f"{SCRIPT_PROMPT}\n\n대사 기록\n{spoken}"}
    ]
    parts += [
        {
            "inline_data": {
                "mime_type": "image/jpeg",
                "data": base64.b64encode(image).decode(),
            }
        }
        for image in images
    ]
    payload = _gms(
        SCRIPT_MODEL,
        {
            "contents": [{"parts": parts}],
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseSchema": _SCRIPT_SCHEMA,
            },
        },
    )
    return parse_script(payload)


# ── 2단계: 그림 ────────────────────────────────────────────────────────────


def build_image_prompt(
    cuts: Sequence[Mapping[str, Any]],
    *,
    characters: Sequence[Mapping[str, str]] = (),
    setting: str = "",
    style: str = DEFAULT_STYLE,
) -> str:
    """이미지 모델에 넣을 프롬프트 한 덩이.

    순서가 규칙이다 — 화풍·배치 → 인물 시트 → 배경 → 컷 → 금지사항. 앞쪽 지시가
    더 강하게 먹힌다.

    **대사(`dialogue`)는 절대 넣지 않는다.** 대사를 보여주면 모델이 그 글자를
    그림에 쓰려고 든다. 대사는 앱이 얹는다.

    인물 문장은 시트에서 **글자 그대로** 옮기고 컷 묘사에서도 같은 label로만
    부른다. 바꿔 부르는 순간 컷마다 다른 사람이 그려진다.
    """
    if len(cuts) != CUT_COUNT:
        raise ComicContractError(f"만화는 {CUT_COUNT}컷이어야 합니다 (받은 것: {len(cuts)}).")

    blocks = [
        f"A single square image: a 4-panel comic in {style} style, 2x2 grid "
        "with thin white gutters. Reading order: top-left (1), top-right (2), "
        "bottom-left (3), bottom-right (4). "
        # 앱이 칸을 그림의 4등분으로 잡고 자막을 앉히므로, 격자 바깥에 여백이
        # 있으면 자막이 칸 중심에서 밀린다. 지켜지지 않을 때를 대비해 서버가
        # 받은 그림에서 테두리를 실제로 잘라내지만(normalize_square_png),
        # 애초에 안 그리게 하는 것이 낫다.
        "The 2x2 grid must fill the entire image edge to edge: no outer border, "
        "no margin, no frame, no matting around the four panels."
    ]
    if characters:
        rows = "\n".join(
            f"- {person['label']}: {person['appearance']}" for person in characters
        )
        blocks.append(
            "CHARACTERS - draw them IDENTICALLY in every panel:\n" + rows
        )
    if setting:
        blocks.append(f"SETTING (all panels): {setting}")
    blocks.append(
        "\n".join(
            f"Panel {index + 1} ({cut['beat']}, {PANEL_POSITIONS[index]}): "
            f"{cut['scene']}"
            for index, cut in enumerate(cuts)
        )
    )
    blocks.append(STRICT_RULES)
    return "\n\n".join(blocks)


def _first_image(payload: Mapping[str, Any]) -> bytes:
    candidates = payload.get("candidates") or []
    if not candidates:
        raise ComicContractError(f"응답에 candidates가 없습니다: {sorted(payload)}")
    parts = (candidates[0].get("content") or {}).get("parts") or []
    for part in parts:
        blob = part.get("inlineData") or part.get("inline_data")
        if blob and blob.get("data"):
            try:
                return base64.b64decode(blob["data"], validate=True)
            except (ValueError, TypeError) as failure:
                raise ComicContractError("그림 base64를 읽지 못했습니다.") from failure
    # 이미지 모델이 아닌 것을 부르면 글만 돌아온다 — 실제로 겪은 실패다.
    raise ComicContractError(
        f"응답에 그림이 없습니다. 모델이 이미지 출력을 지원하는지 확인할 것 "
        f"({IMAGE_MODEL})."
    )


"""자막 띠가 칸 가운데에 앉으려면 2x2 격자가 그림 전체를 채워야 한다.

앱은 칸을 그림의 수학적 4등분으로 잡고 그 가운데에 띠를 앉힌다
(`panel_subtitle.dart`). 그런데 격자를 그리는 것은 모델이고, 모델은 2x2 바깥에
흰 테두리를 함께 그린다 — 실측(1024x1024 만화)에서 사면 40~42px이었다. 그러면
왼쪽 칸의 실제 중심은 272px인데 앱은 256px(25%)에 띠를 앉혀 16px이 바깥으로
밀린다. 좌우가 서로 반대 방향으로 밀리므로 눈에는 "가운데가 아니라 옆으로
빗겨난" 것으로 보인다.

프롬프트로 "테두리를 그리지 마라"고 해도 픽셀 단위로는 지켜지지 않는다. 받은
그림에서 테두리를 실제로 재서 잘라내는 것이 유일하게 확실한 방법이다.
"""

# cropdetect가 stderr에 남기는 값. `crop=w:h:x:y` 형태다.
_CROP_LINE = re.compile(r"crop=(\d+):(\d+):(\d+):(\d+)")

# 한 변에서 이만큼 넘게 잘라내려 하면 테두리 검출을 믿지 않는다. 밝은 화풍의
# 만화는 칸 내용까지 테두리로 오인될 수 있는데, 그때 잘라 버리면 그림이
# 망가진다 — 띠가 조금 빗겨나는 것보다 나쁘다.
_MAX_TRIM_RATIO = 0.2


def parse_crop_box(stderr: str) -> tuple[int, int, int, int] | None:
    """cropdetect 출력에서 마지막 `crop=w:h:x:y`를 뽑는다. 없으면 None."""
    matches = _CROP_LINE.findall(stderr)
    if not matches:
        return None
    width, height, left, top = (int(value) for value in matches[-1])
    return width, height, left, top


def crop_box_is_trustworthy(
    box: tuple[int, int, int, int], width: int, height: int
) -> bool:
    """검출한 내용 영역을 믿을 수 있는가.

    잘라낼 양이 너무 많거나(밝은 화풍을 테두리로 오인) 값이 앞뒤가 맞지 않으면
    믿지 않는다. 검출이 틀렸을 때 원본을 그대로 쓰는 쪽이 안전하다.
    """
    box_width, box_height, left, top = box
    if box_width <= 0 or box_height <= 0:
        return False
    if left < 0 or top < 0:
        return False
    if left + box_width > width or top + box_height > height:
        return False
    trimmed_x = width - box_width
    trimmed_y = height - box_height
    return (
        trimmed_x <= width * _MAX_TRIM_RATIO
        and trimmed_y <= height * _MAX_TRIM_RATIO
    )


def png_size(data: bytes) -> tuple[int, int] | None:
    """PNG의 가로·세로. PNG가 아니거나 너무 짧으면 None.

    IHDR은 항상 파일 앞머리 고정 위치에 있어 헤더만 읽으면 된다 — 이미지
    라이브러리를 서비스 의존성에 넣지 않으려고 직접 읽는다(Pillow·numpy는
    분석 전용 의존성이라 이 경로에 없을 수 있다).
    """
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    width, height = struct.unpack(">II", data[16:24])
    return int(width), int(height)


def _detect_content_box(data: bytes) -> tuple[int, int, int, int] | None:
    """흰 테두리를 뺀 내용 영역. 검출하지 못하거나 믿을 수 없으면 None.

    `cropdetect`는 **어두운** 테두리를 찾으므로 `negate`로 뒤집어 흰 테두리를
    검은 테두리로 만든 뒤 잰다. 검출은 최선 노력이다 — 실패하면 자르지 않는다.
    """
    size = png_size(data)
    try:
        _, stderr = _run_capturing_stderr(
            [
                "ffmpeg",
                "-nostdin",
                "-loglevel",
                "info",
                "-i",
                "pipe:0",
                "-vf",
                # limit=24: 뒤집은 뒤 24 이하(=원본에서 231 이상 밝음)를 테두리로 본다.
                # round=2: 짝수로 맞춰 크로마 서브샘플링과 어긋나지 않게 한다.
                # **skip=0이 없으면 아무것도 검출되지 않는다** — cropdetect는 기본으로
                # 앞 2프레임을 건너뛰는데(skip=2) 정지 이미지에는 프레임이 하나뿐이라
                # 그 하나가 건너뛰어진다. 실서버 만화에서 이것 때문에 조용히
                # 검출 실패했고, 자르지 않은 그림이 그대로 나갔다.
                "negate,cropdetect=limit=24:round=2:skip=0:reset=0",
                "-frames:v",
                "1",
                "-f",
                "null",
                "-",
            ],
            stdin=data,
        )
    except ComicError:
        return None
    box = parse_crop_box(stderr)
    if box is None or size is None:
        return None
    return box if crop_box_is_trustworthy(box, *size) else None


def normalize_square_png(data: bytes) -> bytes:
    """PNG·정사각으로 맞추고, 모델이 그린 외곽 테두리를 잘라낸다.

    앱은 base64 PNG만 받고, 2x2 격자를 전제로 자막을 얹는다. 정사각이 아니면
    `BoxFit.contain`이 위아래 여백을 만들어 자막 네 개가 전부 칸을 벗어난다.
    모델 출력을 믿지 않고 여기서 한 번 맞춘다 — 이미 정사각 PNG면 그대로 다시
    쓰는 셈이라 비용이 없다.

    테두리를 자른 뒤에도 정사각으로 다시 채운다. 실측에서 사면 여백이 거의
    같아(40·41·42·42) 자른 결과가 이미 정사각에 가깝고, 채우는 양은 1~2px이라
    칸 중심을 흩뜨리지 않는다. 늘려서 억지로 정사각을 만들지 않는 이유는 그림이
    비틀리기 때문이다.
    """
    box = _detect_content_box(data)
    crop = ""
    if box is not None:
        box_width, box_height, left, top = box
        crop = f"crop={box_width}:{box_height}:{left}:{top},"
    return _run(
        [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-i",
            "pipe:0",
            "-vf",
            # ffmpeg 필터 문법에서 쉼표는 필터 구분자라 max() 안에서 escape한다.
            crop
            + r"pad=w=max(iw\,ih):h=max(iw\,ih):x=(ow-iw)/2:y=(oh-ih)/2:color=white",
            "-f",
            "image2pipe",
            "-vcodec",
            "png",
            "pipe:1",
        ],
        stdin=data,
    )


def render_comic(
    cuts: Sequence[Mapping[str, Any]],
    *,
    characters: Sequence[Mapping[str, str]] = (),
    setting: str = "",
    style: str = DEFAULT_STYLE,
) -> bytes:
    """4컷 구성 → 2x2 만화 PNG 바이트."""
    payload = _gms(
        IMAGE_MODEL,
        {
            "contents": [
                {
                    "parts": [
                        {
                            "text": build_image_prompt(
                                cuts,
                                characters=characters,
                                setting=setting,
                                style=style,
                            )
                        }
                    ]
                }
            ],
            "generationConfig": {"responseModalities": ["TEXT", "IMAGE"]},
        },
    )
    return normalize_square_png(_first_image(payload))


def usage_summary(payload: Mapping[str, Any]) -> dict[str, int]:
    """응답의 토큰 사용량. 크레딧을 실측할 때 로그로 남긴다.

    `thoughtsTokenCount`도 함께 본다 — 이 모델은 생각 토큰을 쓰고, 색 하나
    묻는 데도 100토큰이 넘었다.
    """
    usage = payload.get("usageMetadata") or {}
    return {
        "prompt": int(usage.get("promptTokenCount", 0) or 0),
        "candidates": int(usage.get("candidatesTokenCount", 0) or 0),
        "thoughts": int(usage.get("thoughtsTokenCount", 0) or 0),
        "total": int(usage.get("totalTokenCount", 0) or 0),
    }
