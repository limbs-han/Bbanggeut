"""사람별 얼굴 궤적. 표정 분석 창을 사람 단위 경로로 이어 붙인다.

앱의 얼굴 추적 스티커와 자동 줌이 같은 궤적을 쓴다 — 스티커가 따라가는 그
사람을 줌도 따라간다.
"""

from __future__ import annotations

import math
from typing import Any

# 이웃 표본이 이보다 멀리 건너뛰면 같은 사람으로 보지 않는다(0~1 좌표).
FACE_LINK_DISTANCE = 0.16
# 이보다 오래 끊긴 얼굴은 새 궤적으로 시작한다. 근처에서 다시 잡히면
# 아래 병합 단계가 다시 이어 붙인다.
FACE_LINK_GAP_MS = 1500
# 이보다 짧게 잡힌 궤적은 오검출로 보고 버린다(250ms 창 4개 = 1초).
FACE_TRACK_MIN_SAMPLES = 4

# 영상 분석(BlazeFace) 얼굴로 궤적의 빈 자리를 메울 때 쓰는 거리 게이트.
# 그 표본에는 "누구인지"가 없다 — 창마다 **가장 큰 얼굴 하나**뿐이라, 가까이
# 있는 궤적에만 붙여야 다른 사람이 섞이지 않는다.
#
# **너무 좁으면 정작 필요한 표본을 버린다.** 처음에 0.06/0.10으로 잡았더니
# 사람이 500ms에 화면의 8%를 걸어간 순간이 "다른 사람"으로 걸러졌다. 가만히
# 있을 때만 붙고 움직이면 잘리니, 정확히 추적이 필요한 구간에서 궤적이
# 끊겼다(실측: 표본 9개 중 우리 사람 3개를 전부 놓쳤다).
_FILL_DISTANCE_ALONE = 0.12
# 한 창에 얼굴이 여럿이면 "가장 큰 얼굴"이 누구인지 더 흔들린다. 조금 좁게 본다.
_FILL_DISTANCE_CROWD = 0.09
# 오래 비어 있었으면 그만큼 멀어질 수 있다. 궤적 잇기(FACE_LINK_DISTANCE)가
# 쓰는 것과 같은 셈법이다. 기준 간격은 영상 분석 창 간격(500ms).
_FILL_SAMPLE_MS = 500
# 아무리 오래 비었어도 이 거리를 넘으면 같은 사람으로 보지 않는다. 실측에서
# 옆 사람까지는 0.4 넘게 떨어져 있어, 이 상한이면 걸러야 할 것은 그대로
# 걸러진다.
_FILL_DISTANCE_MAX = 0.30
# 이 표본에서 이보다 멀리 떨어진 궤적에는 붙이지 않는다 — 그만큼 비어 있으면
# 같은 사람이라고 볼 근거가 없다.
_FILL_REACH_MS = 3000
# 시간이 거의 같은 표본만 건너뛴다. 표정 분석 표본 **바로 뒤**의 영상 표본은
# 중복이 아니라 그 사이의 움직임이다 — 250ms로 잡았을 때 그것까지 버려서,
# 사람이 움직이기 시작한 순간이 통째로 사라졌다.
_FILL_KEEP_MS = 120
# 얼굴 상자의 가로세로 비. 영상 분석은 넓이만 남기므로 높이를 되짚을 때 쓴다.
_FACE_ASPECT = 0.75


def flat_face_track(expression: dict[str, Any]) -> list[dict[str, float]]:
    """옛 앱이 쓰는 한 줄짜리 얼굴 궤적.

    expression 분석의 250ms 창에서 얼굴이 잡힌 것만 추린다. 시각은 창의
    가운데(원본 영상 기준 ms), 좌표는 0~1 정규화 얼굴 중심, h는 화면 대비
    얼굴 높이다. 얼굴이 없는 구간은 비워 둔다 — 앱이 이웃 표본을 보간한다.
    """
    track: list[dict[str, float]] = []
    for row in expression.get("expressionWindows", []):
        if int(row.get("faceCount", 0)) <= 0:
            continue
        height = float(row.get("faceHeight", 0.0))
        if height <= 0.0:
            continue
        track.append(
            {
                "ms": (int(row["startMs"]) + int(row["endMs"])) // 2,
                "x": round(float(row.get("focusX", 0.5)), 4),
                "y": round(float(row.get("focusY", 0.5)), 4),
                "h": round(height, 4),
            }
        )
    return track


def _fill_from_video(
    tracks: list[dict[str, Any]], video: dict[str, Any]
) -> None:
    """영상 분석이 잡은 얼굴로 궤적의 빈 자리를 메운다.

    **왜 필요한가**: 표정 분석(FaceLandmarker)은 랜드마크 478개를 맞춰야 해서
    고개를 기울이거나 작은 얼굴을 자주 놓친다 — 어떤 영상에서는 창의 8%만
    잡는다. 같은 영상에서 영상 분석(BlazeFace)은 57%를 잡는다. 표정 점수는
    전자가 맞지만, "지금 얼굴이 어디 있나"는 후자가 훨씬 촘촘하다. 그 자리를
    빌려 오면 재분석 없이도 줌이 사람을 따라갈 수 있다.

    영상 분석은 창마다 **가장 큰 얼굴 하나**만 남기므로 누구인지가 없다.
    그래서 이미 있는 궤적에 **가까이 붙을 때만** 채우고, 새 궤적은 열지
    않는다 — 여러 명이 나올 때 엉뚱한 사람을 따라가는 것보다 안 따라가는
    쪽이 낫다.
    """
    for row in video.get("videoWindows", []):
        count = int(row.get("faceCount", 0) or 0)
        area = float(row.get("largestFaceArea", 0.0) or 0.0)
        if count <= 0 or area <= 0.0:
            continue
        ms = (int(row["startMs"]) + int(row["endMs"])) // 2
        x = float(row.get("faceCenterX", 0.5))
        y = float(row.get("faceCenterY", 0.5))
        height = min(1.0, math.sqrt(area / _FACE_ASPECT))
        base = _FILL_DISTANCE_ALONE if count == 1 else _FILL_DISTANCE_CROWD
        best = None
        best_distance = None
        for track in tracks:
            samples = track["samples"]
            near = min(samples, key=lambda item: abs(int(item["ms"]) - ms))
            gap = abs(int(near["ms"]) - ms)
            if gap <= _FILL_KEEP_MS or gap > _FILL_REACH_MS:
                # 같은 순간이 이미 있거나, 너무 멀어 근거가 없다.
                continue
            here = sample_at(samples, ms)
            if here is None:
                continue
            # 오래 비어 있었으면 그만큼 멀어질 수 있다.
            gate = min(
                _FILL_DISTANCE_MAX,
                base * min(3.0, max(1.0, gap / _FILL_SAMPLE_MS)),
            )
            distance = math.hypot(x - here["x"], y - here["y"])
            if distance <= gate and (
                best_distance is None or distance < best_distance
            ):
                best = track
                best_distance = distance
        if best is None:
            continue
        best["samples"].append(
            {
                "ms": ms,
                "x": round(x, 4),
                "y": round(y, 4),
                "h": round(height, 4),
                "w": round(height * _FACE_ASPECT, 4),
                # 어디서 온 표본인지 남긴다 — 표정 점수는 이 자리에 없다.
                "src": "video",
            }
        )
    for track in tracks:
        track["samples"].sort(key=lambda item: int(item["ms"]))


def build_face_tracks(
    expression: dict[str, Any], video: dict[str, Any] | None = None
) -> list[dict[str, Any]]:
    """사람별 얼굴 궤적. 앱의 얼굴 추적 스티커가 '누구'를 고를 수 있게 한다.

    v3 분석은 창마다 검출된 얼굴 전부(`faces`)를 남긴다. 창을 시간 순으로
    돌며 각 얼굴을 살아 있는 궤적 중 가장 가까운 것에 붙이고, 붙일 곳이
    없으면 새 궤적을 연다. 옛(v2) 분석은 최강 얼굴 하나만 있으므로 그대로
    한 줄로 잇는다 — 그 경우 사람 구분은 앱의 연속 구간 나누기가 맡는다.
    """
    tracks: list[dict[str, Any]] = []
    for row in expression.get("expressionWindows", []):
        faces = row.get("faces")
        if faces is None:
            if int(row.get("faceCount", 0)) <= 0:
                continue
            faces = [
                {
                    "focusX": row.get("focusX", 0.5),
                    "focusY": row.get("focusY", 0.5),
                    "faceHeight": row.get("faceHeight", 0.0),
                    "faceWidth": row.get("faceWidth", 0.0),
                }
            ]
        ms = (int(row["startMs"]) + int(row["endMs"])) // 2
        claimed: set[int] = set()
        for face in faces:
            height = float(face.get("faceHeight", 0.0))
            if height <= 0.0:
                continue
            x = float(face.get("focusX", 0.5))
            y = float(face.get("focusY", 0.5))
            best = None
            best_distance = None
            for candidate in tracks:
                if id(candidate) in claimed:
                    continue
                last = candidate["samples"][-1]
                gap = ms - int(last["ms"])
                if gap > FACE_LINK_GAP_MS:
                    continue
                allowed = FACE_LINK_DISTANCE * min(3.0, max(1.0, gap / 250))
                distance = math.hypot(x - last["x"], y - last["y"])
                if distance <= allowed and (
                    best_distance is None or distance < best_distance
                ):
                    best = candidate
                    best_distance = distance
            if best is None:
                best = {"id": f"face-{len(tracks) + 1}", "samples": []}
                tracks.append(best)
            claimed.add(id(best))
            best["samples"].append(
                {
                    "ms": ms,
                    "x": round(x, 4),
                    "y": round(y, 4),
                    "h": round(height, 4),
                    # 얼굴 **폭**. 줌이 "이 이상 키우면 얼굴이 화면 밖으로
                    # 나간다"를 계산할 때 쓴다. 옛 앱은 이 키를 그냥 무시한다.
                    #
                    # 폭을 안 남긴 옛 분석(expression-v2)에서는 높이로 어림한다
                    # — 0을 그대로 쓰면 얼굴이 점이 되어 상한이 무한정 열린다.
                    "w": round(float(face.get("faceWidth") or height * 0.75), 4),
                }
            )
    # 오래 자리를 비웠다 같은 자리에서 다시 잡힌 궤적은 같은 사람이다.
    merged: list[dict[str, Any]] = []
    for track in sorted(tracks, key=lambda item: item["samples"][0]["ms"]):
        target = None
        for candidate in merged:
            last = candidate["samples"][-1]
            first = track["samples"][0]
            if int(first["ms"]) <= int(last["ms"]):
                continue
            if (
                math.hypot(first["x"] - last["x"], first["y"] - last["y"])
                <= FACE_LINK_DISTANCE
            ):
                target = candidate
                break
        if target is None:
            merged.append(track)
        else:
            target["samples"].extend(track["samples"])
    # 빈 자리 메우기는 **오검출을 걸러낸 뒤**에 한다. 표본이 하나뿐인 헛
    # 검출에 영상 분석 얼굴이 붙어 궤적처럼 살아나면 안 된다.
    solid = [
        track for track in merged if len(track["samples"]) >= FACE_TRACK_MIN_SAMPLES
    ]
    if video:
        _fill_from_video(solid, video)
    solid.sort(key=lambda item: len(item["samples"]), reverse=True)
    return [
        {"id": f"face-{index + 1}", "samples": track["samples"]}
        for index, track in enumerate(solid)
    ]


def sample_at(
    samples: list[dict[str, float]], ms: int
) -> dict[str, float] | None:
    """[ms] 순간의 얼굴 표본. 이웃을 선형 보간하고, 궤적 바깥은 끝 표본이다.

    앱(`EditorProject._sampleOn`)과 같은 규칙이다 — 궤적을 서버에서 굽든
    앱에서 읽든 같은 자리가 나와야 한다.
    """
    if not samples:
        return None
    if ms <= int(samples[0]["ms"]):
        return samples[0]
    if ms >= int(samples[-1]["ms"]):
        return samples[-1]
    for index in range(1, len(samples)):
        following = samples[index]
        if ms > int(following["ms"]):
            continue
        previous = samples[index - 1]
        span = int(following["ms"]) - int(previous["ms"])
        if span <= 0:
            return following
        ratio = (ms - int(previous["ms"])) / span
        blend = lambda key, fallback: previous.get(key, fallback) + (
            following.get(key, fallback) - previous.get(key, fallback)
        ) * ratio
        return {
            "ms": float(ms),
            "x": blend("x", 0.5),
            "y": blend("y", 0.5),
            "h": blend("h", 0.0),
            "w": blend("w", 0.0),
        }
    return samples[-1]
