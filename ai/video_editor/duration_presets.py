"""Apply a user-selected output length to an adaptive story selection."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Literal

from .cut_selector import select_cut
from .models import ScoreSegment, SelectorConfig

DurationPresetName = Literal["auto", "short", "medium", "long"]


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
    duration_ms = int(selection["durationMs"])
    if preset.minimum_ms <= duration_ms <= preset.maximum_ms:
        return {**selection, "durationPreset": preset_name}

    boundaries = _boundary_scores(yamnet_analysis, video_analysis)
    segments = []
    for row in timeline:
        start_ms = int(row["startMs"])
        end_ms = int(row["endMs"])
        edit_score = min(
            1.0,
            0.85 * float(row["eventScore"])
            + 0.15 * float(row["continuityScore"]),
        )
        segments.append(
            ScoreSegment(
                start_ms=start_ms,
                end_ms=end_ms,
                edit_score=edit_score,
                start_boundary_score=boundaries.get(start_ms, 0.35),
                end_boundary_score=boundaries.get(end_ms, 0.35),
            )
        )
    result = select_cut(
        duration_ms=int(yamnet_analysis["durationMs"]),
        anchor_start_ms=int(selection["seedStartMs"]),
        anchor_end_ms=int(selection["seedEndMs"]),
        segments=segments,
        config=SelectorConfig(
            min_duration_ms=preset.minimum_ms,
            max_duration_ms=preset.maximum_ms,
            context_before_ms=preset.context_before_ms,
            context_after_ms=preset.context_after_ms,
            content_weight=0.68,
            start_boundary_weight=0.14,
            end_boundary_weight=0.14,
            context_weight=0.04,
            extra_second_penalty=0.0005,
        ),
    )
    return {
        **selection,
        "startMs": result.start_ms,
        "endMs": result.end_ms,
        "durationMs": result.duration_ms,
        "durationPreset": preset_name,
        "presetSelectionReason": result.reason,
        "presetCandidateCount": result.candidate_count,
    }
