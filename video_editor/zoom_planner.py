"""Create sparse, expression-driven hard zoom moments."""

from __future__ import annotations

import math
import statistics
from typing import Any


def _smooth(values: list[float], radius: int = 1) -> list[float]:
    output = []
    for index in range(len(values)):
        start = max(0, index - radius)
        end = min(len(values), index + radius + 1)
        output.append(sum(values[start:end]) / (end - start))
    return output


def plan_zoom_segments(
    timeline: list[dict[str, Any]],
    expression_analysis: dict[str, Any] | None,
    cut: dict[str, Any],
    *,
    enabled: bool,
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
        zooms.append(
            {
                "startMs": start_ms,
                "endMs": end_ms,
                "scale": round(scale, 6),
                "focusX": round(max(0.12, min(0.88, float(row["focusX"]))), 6),
                "focusY": round(max(0.12, min(0.88, float(row["focusY"]))), 6),
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
