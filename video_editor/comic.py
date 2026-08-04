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

# **5장이 상한이다. 늘리지 마라.** GMS 프록시가 요청 본문 약 100KB에서 끊는다 —
# 실측(2026-08-03, 139초 영상, 512폭 q5 JPEG): 5장 base64 86KB는 통과하고
# 6장 103KB는 `contents is not specified`(400)로 거부된다. 프레임 자체가 아니라
# **요청 크기** 문제라서, 더 넣고 싶으면 FRAME_WIDTH나 JPEG 품질을 먼저 낮춰야 한다.
FRAME_LIMIT = 5
FRAME_COUNT = max(1, min(FRAME_LIMIT, int(os.environ.get("COMIC_FRAME_COUNT", "5"))))

# 프레임 해상도는 토큰 수와 무관하다(장당 약 1,100토큰 고정 — 1장 1,766 대 5장
# 6,166으로 실측). 줄이는 것은 **요청 크기**뿐이고, 위 100KB 제한이 그래서 중요하다.
FRAME_WIDTH = 512

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
STRICT_RULES = """STRICT RULES:
- No text, no letters, no numbers anywhere in the image.
- No speech bubbles, no thought bubbles, no sound effects.
- No captions, no watermarks, no camera UI, no timestamps.
- Keep the lower quarter of each panel visually simple: the app overlays
  subtitles there."""

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


def extract_frames(video_url: str, count: int = FRAME_COUNT) -> list[bytes]:
    """원본에서 JPEG 프레임 몇 장을 뽑는다. presigned URL을 그대로 먹인다.

    [FRAME_LIMIT]을 넘겨 부르면 잘라 낸다 — 넘기면 GMS가 요청을 거부하므로,
    많이 달라는 요청을 그대로 따르면 아예 실패한다.
    """
    frames: list[bytes] = []
    count = max(1, min(FRAME_LIMIT, count))
    for at in frame_timestamps(video_duration_seconds(video_url), count):
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
                "5",
                "pipe:1",
            ]
        )
        if jpeg:
            frames.append(jpeg)
    if not frames:
        raise ComicError("영상에서 프레임을 뽑지 못했습니다.")
    return frames


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
) -> dict[str, Any]:
    """프레임 + 자막 → 4컷 구성과 인물·배경 시트.

    `frames`를 주면 추출을 건너뛴다 — 테스트와 재시도용이다.
    """
    images = list(frames) if frames is not None else extract_frames(video_url, count)
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
        "bottom-left (3), bottom-right (4)."
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


def normalize_square_png(data: bytes) -> bytes:
    """PNG·정사각으로 맞춘다.

    앱은 base64 PNG만 받고, 2x2 격자를 전제로 자막을 얹는다. 정사각이 아니면
    `BoxFit.contain`이 위아래 여백을 만들어 자막 네 개가 전부 칸을 벗어난다.
    모델 출력을 믿지 않고 여기서 한 번 맞춘다 — 이미 정사각 PNG면 그대로 다시
    쓰는 셈이라 비용이 없다.
    """
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
            r"pad=w=max(iw\,ih):h=max(iw\,ih):x=(ow-iw)/2:y=(oh-ih)/2:color=white",
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
