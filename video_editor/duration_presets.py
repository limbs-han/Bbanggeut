"""Apply a user-selected output length to an adaptive story selection."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Literal

DurationPresetName = Literal["auto", "short", "medium", "long"]

# 내용 점수가 최고의 이 비율 이상인 구간만 경계 비교 대상에 올린다.
CONTENT_TOLERANCE = 0.99


@dataclass(frozen=True, slots=True)
class DurationPreset:
    minimum_ms: int
    maximum_ms: int
    context_before_ms: int
    context_after_ms: int


PRESETS: dict[str, DurationPreset] = {
    "short": DurationPreset(15_000, 30_000, 4_000, 4_000),
    "medium": DurationPreset(35_000, 65_000, 10_000, 10_000),
    "long": DurationPreset(70_000, 120_000, 15_000, 15_000),
}


def _boundary_scores(
    yamnet_analysis: dict[str, Any],
    video_analysis: dict[str, Any] | None,
) -> dict[int, float]:
    duration_ms = int(yamnet_analysis["durationMs"])
    scores = {0: 1.0, duration_ms: 1.0}
    for window in yamnet_analysis.get("yamnetWindows", []):
        speech = float(window.get("speechScore", 0.0))
        laughter = float(window.get("laughterScore", 0.0))
        music = float(window.get("musicScore", 0.0))
        silence = float(window.get("silenceScore", 0.0))
        if max(speech, laughter, music) < 0.20 or silence >= 0.35:
            score = min(0.90, 0.65 + 0.25 * silence)
            for key in ("startMs", "endMs"):
                timestamp = int(window[key])
                scores[timestamp] = max(scores.get(timestamp, 0.0), score)
    if video_analysis:
        for window in video_analysis.get("videoWindows", []):
            scene_cut = float(window.get("sceneCutScore", 0.0))
            if scene_cut >= 0.55:
                timestamp = int(window["startMs"])
                scores[timestamp] = max(scores.get(timestamp, 0.0), 0.70 + 0.25 * scene_cut)
    return scores


def apply_duration_preset(
    selection: dict[str, Any],
    timeline: list[dict[str, Any]],
    yamnet_analysis: dict[str, Any],
    video_analysis: dict[str, Any] | None,
    preset_name: DurationPresetName,
) -> dict[str, Any]:
    if preset_name == "auto":
        return {**selection, "durationPreset": "auto"}
    if preset_name not in PRESETS:
        raise ValueError(f"unknown duration preset: {preset_name}")
    preset = PRESETS[preset_name]
    if not timeline:
        return {**selection, "durationPreset": preset_name}

    boundaries = _boundary_scores(yamnet_analysis, video_analysis)
    bins = [
        (
            int(row["startMs"]),
            int(row["endMs"]),
            min(
                1.0,
                0.85 * float(row["eventScore"])
                + 0.15 * float(row["continuityScore"]),
            ),
        )
        for row in timeline
    ]
    prefix = [0.0]
    for _, _, score in bins:
        prefix.append(prefix[-1] + score)

    count = len(bins)
    minimum_bins = max(1, preset.minimum_ms // (bins[0][1] - bins[0][0]))
    maximum_bins = max(minimum_bins, preset.maximum_ms // (bins[0][1] - bins[0][0]))

    # 프리셋 범위에 드는 모든 구간을 전수 나열해 내용 점수로 비교한다.
    # seed 포함이나 앞뒤 문맥을 강제하지 않는다 — 강제하면 좋은 구간을 놓친다.
    candidates = []
    for left in range(count):
        upper = min(count, left + maximum_bins)
        for right in range(left + minimum_bins, upper + 1):
            content = (prefix[right] - prefix[left]) / (right - left)
            start_ms = bins[left][0]
            end_ms = bins[right - 1][1]
            candidates.append((content, start_ms, end_ms))
    if not candidates:
        return {**selection, "durationPreset": preset_name}

    # 경계 품질은 점수에 섞지 않는다. 섞으면 경계 차이(최대 0.65)가 내용 차이
    # (보통 0.02)를 압도해서 영상 맨 끝에 붙는 구간만 이긴다. 내용으로 먼저
    # 거른 뒤 그 안에서만 끊기 좋은 자리를 고른다.
    best_content = max(item[0] for item in candidates)
    pool = [
        item
        for item in candidates
        if item[0] >= best_content * CONTENT_TOLERANCE
    ]
    content, start_ms, end_ms = max(
        pool,
        key=lambda item: (
            round(
                boundaries.get(item[1], 0.35) + boundaries.get(item[2], 0.35), 9
            ),
            round(item[0], 9),
            -(item[2] - item[1]),
            -item[1],
        ),
    )
    return {
        **selection,
        "startMs": start_ms,
        "endMs": end_ms,
        "durationMs": end_ms - start_ms,
        "durationPreset": preset_name,
        "presetSelectionReason": "highest_content_then_safest_boundary",
        "presetCandidateCount": len(candidates),
        "presetContentScore": round(content, 6),
    }
