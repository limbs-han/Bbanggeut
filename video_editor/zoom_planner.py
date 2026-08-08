"""Create sparse, expression-driven hard zoom moments."""

from __future__ import annotations

import math
import statistics
from typing import Any

from .face_tracks import sample_at

# 초점이 이 안에서 흔들리는 것은 얼굴이 움직인 게 아니라 검출 떨림이다.
# 확대 중에는 화면에서 배로 커 보이므로 무시한다(0~1 좌표).
_FOCUS_DEAD_ZONE = 0.012
# 초점 키프레임 간격. 표정 분석 창(250ms)과 같은 격자에 둔다.
_FOCUS_SAMPLE_MS = 250
# 줌 초점이 화면 가장자리까지 가지 않게 막는 여유. 정지 초점과 같은 값이다.
_FOCUS_MIN = 0.12
_FOCUS_MAX = 0.88
# 줌이 잡은 얼굴과 궤적이 이보다 멀면 다른 사람으로 본다. 사람 사이를 가르는
# 거리(0.16)의 절반보다 좁다 — 같은 검출에서 나온 궤적은 거의 겹친다.
_FOCUS_MATCH_DISTANCE = 0.06
# 얼굴 상자와 화면 가장자리 사이에 남겨 둘 여백(화면 대비).
_FRAME_SAFE_MARGIN = 0.02
# 안전 상한이 아무리 빡빡해도 이보다 밑으로는 내리지 않는다. 여기까지 왔다는
# 것은 얼굴이 이미 화면 끝에 붙어 있다는 뜻이라, 줌을 더 줄여도 살릴 수 없다.
_MIN_SAFE_SCALE = 1.20


def _smooth(values: list[float], radius: int = 1) -> list[float]:
    output = []
    for index in range(len(values)):
        start = max(0, index - radius)
        end = min(len(values), index + radius + 1)
        output.append(sum(values[start:end]) / (end - start))
    return output


def _track_at(
    face_tracks: list[dict[str, Any]], center_ms: int, focus_x: float, focus_y: float
) -> dict[str, Any] | None:
    """이 순간 이 자리에 있는 사람의 궤적.

    줌은 표정이 가장 센 얼굴을 잡는다. 그 얼굴이 어느 사람의 궤적인지는
    같은 순간·같은 자리에 있는 궤적으로 찾는다 — 그래야 확대해 놓은 채로
    그 사람만 따라갈 수 있다.

    [center_ms]는 표정 분석 창의 한가운데, 곧 궤적 표본이 놓인 바로 그
    시각이다. 같은 검출에서 나온 궤적이면 거의 정확히 겹친다 — 옆 사람을
    잘못 집어 엉뚱한 얼굴을 따라가지 않게 좁게 본다.
    """
    best = None
    best_distance = None
    for track in face_tracks:
        samples = track.get("samples") or []
        if not samples:
            continue
        # 궤적이 이 순간을 덮지 않으면 다른 사람이다. 표본은 250ms 간격이라
        # 양 끝에 그만큼 여유를 준다.
        if not (
            int(samples[0]["ms"]) - _FOCUS_SAMPLE_MS
            <= center_ms
            <= int(samples[-1]["ms"]) + _FOCUS_SAMPLE_MS
        ):
            continue
        sample = sample_at(samples, center_ms)
        if sample is None:
            continue
        distance = math.hypot(sample["x"] - focus_x, sample["y"] - focus_y)
        if distance > _FOCUS_MATCH_DISTANCE:
            continue
        if best_distance is None or distance < best_distance:
            best = track
            best_distance = distance
    return best


def _plan_focus_track(
    samples: list[dict[str, float]],
    start_ms: int,
    end_ms: int,
    focus_x: float,
    focus_y: float,
) -> list[dict[str, float]]:
    """움직이는 사람을 따라가는 초점 키프레임(정지 초점 대비 이동량).

    `focusX/focusY`에서 얼마나 옮길지(dx·dy)를 담는다 — 절대 좌표가 아니라
    이동량이라 편집기에서 초점을 손으로 끌면 경로 전체가 같이 따라온다.

    날 표본을 그대로 쓰면 확대된 화면이 잘게 떨린다. 이웃 표본을 평균 낸 뒤
    죽은 구간만큼 뒤에서 따라간다 — 그 안에서 떠는 검출은 무시하고, 사람이
    실제로 자리를 옮기면 그 차이만큼만 부드럽게 쫓아간다.
    """
    times = list(range(start_ms, end_ms + 1, _FOCUS_SAMPLE_MS))
    if times[-1] != end_ms:
        times.append(end_ms)
    raw = [sample_at(samples, ms) for ms in times]
    if any(point is None for point in raw):
        return []
    # 이웃 ±1 표본(=±250ms) 평균. 표정 점수 다듬기와 같은 창이다.
    smooth_x = _smooth([float(point["x"]) for point in raw], 1)
    smooth_y = _smooth([float(point["y"]) for point in raw], 1)
    track: list[dict[str, float]] = []
    held_x = focus_x
    held_y = focus_y
    for index, ms in enumerate(times):
        target_x = min(_FOCUS_MAX, max(_FOCUS_MIN, smooth_x[index]))
        target_y = min(_FOCUS_MAX, max(_FOCUS_MIN, smooth_y[index]))
        distance = math.hypot(target_x - held_x, target_y - held_y)
        if distance > _FOCUS_DEAD_ZONE:
            # 죽은 구간만 남기고 따라붙는다. 사람이 계속 걸어가면 초점도
            # 같은 속도로 따라가고, 멈추면 그 자리에서 멈춘다.
            ratio = (distance - _FOCUS_DEAD_ZONE) / distance
            held_x += (target_x - held_x) * ratio
            held_y += (target_y - held_y) * ratio
        track.append(
            {
                "ms": ms,
                "dx": round(held_x - focus_x, 6),
                "dy": round(held_y - focus_y, 6),
            }
        )
    if all(abs(point["dx"]) < 1e-6 and abs(point["dy"]) < 1e-6 for point in track):
        return []
    return track


def _max_safe_scale(
    samples: list[dict[str, float]],
    focus_track: list[dict[str, float]],
    start_ms: int,
    end_ms: int,
    focus_x: float,
    focus_y: float,
) -> float:
    """얼굴 상자가 화면 안에 남는 가장 큰 배율.

    확대는 초점을 축으로 한다 — 원본의 점 p는 화면의 `f + (p-f)*s`로 간다.
    그러니 얼굴 상자의 네 변이 화면(0~1) 안에 있으려면 배율이 변마다 정해지는
    한계 밑이어야 한다. 구간 내내 성립해야 하므로 가장 빡빡한 순간을 따른다.

    **왜 서버가 정하나**: 얼마나 크게 볼지는 취향이라 앱이 정하지만, "이 이상은
    얼굴이 잘린다"는 것은 얼굴 상자와 초점만으로 정해지는 기하학이다. 그 값을
    아는 쪽은 얼굴 상자를 들고 있는 여기다.
    """
    times = (
        [int(point["ms"]) for point in focus_track]
        if focus_track
        else list(range(start_ms, end_ms + 1, _FOCUS_SAMPLE_MS))
    )
    offsets = {int(point["ms"]): point for point in focus_track}
    limit = 2.80
    for ms in times:
        sample = sample_at(samples, ms)
        if sample is None:
            continue
        moved = offsets.get(ms)
        fx = focus_x + float(moved["dx"]) if moved else focus_x
        fy = focus_y + float(moved["dy"]) if moved else focus_y
        half_w = float(sample.get("w", 0.0)) / 2.0
        half_h = float(sample.get("h", 0.0)) / 2.0
        edges = (
            (sample["x"] - half_w, fx),
            (sample["x"] + half_w, fx),
            (sample["y"] - half_h, fy),
            (sample["y"] + half_h, fy),
        )
        for point, focus in edges:
            if point < focus:
                room = focus - _FRAME_SAFE_MARGIN
                gap = focus - point
            elif point > focus:
                room = 1.0 - _FRAME_SAFE_MARGIN - focus
                gap = point - focus
            else:
                continue
            if gap <= 0:
                continue
            limit = min(limit, max(0.0, room) / gap)
    return round(max(_MIN_SAFE_SCALE, min(2.80, limit)), 6)


def plan_zoom_segments(
    timeline: list[dict[str, Any]],
    expression_analysis: dict[str, Any] | None,
    cut: dict[str, Any],
    *,
    enabled: bool,
    face_tracks: list[dict[str, Any]] | None = None,
) -> list[dict[str, Any]]:
    if not enabled or not expression_analysis:
        return []
    cut_start = int(cut["startMs"])
    cut_end = int(cut["endMs"])
    rows = [
        row
        for row in expression_analysis.get("expressionWindows", [])
        if int(row["startMs"]) >= cut_start + 1_000
        and int(row["endMs"]) <= cut_end - 1_000
        and int(row.get("faceCount", 0)) > 0
        and float(row.get("faceHeight", 0.0)) > 0.0
    ]
    if not rows:
        return []
    expression_scores = _smooth(
        [float(row.get("reactionScore", 0.0)) for row in rows], 1
    )

    def sound_score(row: dict[str, Any]) -> float:
        midpoint = (int(row["startMs"]) + int(row["endMs"])) // 2
        matched = next(
            (
                item
                for item in timeline
                if int(item["startMs"]) <= midpoint < int(item["endMs"])
            ),
            None,
        )
        if matched is None:
            return 0.0
        features = matched.get("features", {})
        return min(
            1.0,
            max(
                float(features.get("laughter", 0.0)),
                float(features.get("reaction", 0.0)),
                0.80 * float(features.get("loudnessRise", 0.0)),
                float(matched.get("socialEvent", 0.0)),
                float(matched.get("ambientEvent", 0.0)),
            ),
        )

    sound_scores = _smooth([sound_score(row) for row in rows], 1)
    expression_baseline = statistics.median(expression_scores)
    expression_peak = max(expression_scores)
    expression_threshold = max(
        0.40,
        expression_baseline
        + 0.40 * max(0.0, expression_peak - expression_baseline),
    )
    sound_baseline = statistics.median(sound_scores)
    sound_peak = max(sound_scores)
    sound_threshold = max(
        0.15, sound_baseline + 0.35 * max(0.0, sound_peak - sound_baseline)
    )
    scores = [
        0.65 * expression + 0.35 * sound
        for expression, sound in zip(expression_scores, sound_scores)
    ]
    candidates = []
    for index, score in enumerate(scores):
        previous = scores[index - 1] if index > 0 else -1.0
        following = scores[index + 1] if index + 1 < len(scores) else -1.0
        if (
            expression_scores[index] >= expression_threshold
            and sound_scores[index] >= sound_threshold
            and score >= previous
            and score >= following
        ):
            candidates.append((score, rows[index]))
    candidates.sort(key=lambda item: item[0], reverse=True)
    max_zooms = max(1, min(4, math.ceil((cut_end - cut_start) / 30_000)))
    selected: list[tuple[float, dict[str, Any]]] = []
    for score, row in candidates:
        center = (int(row["startMs"]) + int(row["endMs"])) // 2
        if any(
            abs(center - (int(other["startMs"]) + int(other["endMs"])) // 2)
            < 10_000
            for _, other in selected
        ):
            continue
        selected.append((score, row))
        if len(selected) >= max_zooms:
            break

    if not selected:
        return []
    selected_peak = max(score for score, _ in selected)
    selection_floor = min(score for score, _ in selected)
    zooms = []
    for score, row in sorted(selected, key=lambda item: int(item[1]["startMs"])):
        row_index = rows.index(row)
        center_ms = (int(row["startMs"]) + int(row["endMs"])) // 2
        left = row_index
        right = row_index
        while left > 0:
            if (
                expression_scores[left - 1] < 0.65 * expression_threshold
                or sound_scores[left - 1] < 0.65 * sound_threshold
            ):
                break
            left -= 1
        while right + 1 < len(rows):
            if (
                expression_scores[right + 1] < 0.65 * expression_threshold
                or sound_scores[right + 1] < 0.65 * sound_threshold
            ):
                break
            right += 1
        natural_start = int(rows[left]["startMs"]) - 250
        natural_end = int(rows[right]["endMs"]) + 500
        natural_duration = natural_end - natural_start
        target_duration = max(1_200, min(4_000, natural_duration))
        if natural_duration > 4_000:
            start_ms = center_ms - 750
        elif natural_duration < 1_200:
            start_ms = center_ms - 400
        else:
            start_ms = natural_start
        start_ms = max(cut_start, start_ms)
        end_ms = min(cut_end, start_ms + target_duration)
        if end_ms - start_ms < target_duration:
            start_ms = max(cut_start, end_ms - target_duration)
        face_height = float(row["faceHeight"])
        intensity = (
            1.0
            if selected_peak <= selection_floor
            else (score - selection_floor) / (selected_peak - selection_floor)
        )
        # Keep reaction faces between roughly one quarter and one third height.
        target_face_height = 0.28 + (1.0 / 3.0 - 0.28) * max(
            0.0, min(1.0, intensity)
        )
        scale = max(1.20, min(2.80, target_face_height / max(0.01, face_height)))
        current_index = rows.index(row)
        focus_x = round(max(_FOCUS_MIN, min(_FOCUS_MAX, float(row["focusX"]))), 6)
        focus_y = round(max(_FOCUS_MIN, min(_FOCUS_MAX, float(row["focusY"]))), 6)
        # 확대해 둔 채로 그 사람이 움직이면 화면 밖으로 나간다. 잡은 얼굴의
        # 궤적을 찾아 초점을 함께 옮긴다 — 스티커가 따라가는 그 궤적이다.
        # 사람 찾기는 자르지 않은 원래 얼굴 자리로 한다 — 가장자리 얼굴은
        # 초점이 안쪽으로 당겨져 있어 그대로 재면 자기 궤적을 놓친다.
        followed = _track_at(
            face_tracks or [],
            center_ms,
            float(row["focusX"]),
            float(row["focusY"]),
        )
        focus_track = (
            _plan_focus_track(
                followed["samples"], start_ms, end_ms, focus_x, focus_y
            )
            if followed
            else []
        )
        # 앱은 얼굴을 더 크게 보고 싶어 배율을 다시 잡는다. 그때 넘지 말아야
        # 할 선을 함께 보낸다 — 화면 가장자리에 선 사람은 조금만 키워도
        # 얼굴이 잘려 나간다.
        max_scale = (
            _max_safe_scale(
                followed["samples"], focus_track, start_ms, end_ms, focus_x, focus_y
            )
            if followed
            else 2.80
        )
        zooms.append(
            {
                "startMs": start_ms,
                "endMs": end_ms,
                "scale": round(scale, 6),
                "maxScale": max_scale,
                "focusX": focus_x,
                "focusY": focus_y,
                "faceTrackId": followed["id"] if focus_track else None,
                "focusTrack": focus_track,
                "rampMs": 0,
                "expressionScore": round(expression_scores[current_index], 6),
                "soundScore": round(sound_scores[current_index], 6),
                "combinedScore": round(score, 6),
                "targetFaceHeight": round(target_face_height, 6),
                "expression": str(row.get("dominantExpression", "reaction")),
                "reason": "expression-and-sound-reaction",
            }
        )
    return zooms
