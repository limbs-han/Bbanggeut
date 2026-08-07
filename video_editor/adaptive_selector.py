"""Adaptive highlight selection over a one-second multimodal timeline."""

from __future__ import annotations

from dataclasses import dataclass
import math
import statistics
from typing import Any


@dataclass(frozen=True, slots=True)
class AdaptiveConfig:
    bin_ms: int = 1_000
    minimum_duration_ms: int = 8_000
    maximum_duration_ms: int = 120_000
    low_tail_bins: int = 3
    boundary_search_ms: int = 3_000


def _overlap(start_ms: int, end_ms: int, item: dict[str, Any]) -> int:
    return max(0, min(end_ms, int(item["endMs"])) - max(start_ms, int(item["startMs"])))


def _max_feature(
    start_ms: int,
    end_ms: int,
    items: list[dict[str, Any]],
    key: str,
) -> float:
    return max(
        (float(item.get(key, 0.0)) for item in items if _overlap(start_ms, end_ms, item)),
        default=0.0,
    )


def _mean_feature(
    start_ms: int,
    end_ms: int,
    items: list[dict[str, Any]],
    key: str,
) -> float:
    weighted = 0.0
    covered = 0
    for item in items:
        overlap_ms = _overlap(start_ms, end_ms, item)
        weighted += overlap_ms * float(item.get(key, 0.0))
        covered += overlap_ms
    return weighted / covered if covered else 0.0


def _cosine_distance(
    left: dict[str, float], right: dict[str, float]
) -> float:
    keys = left.keys() | right.keys()
    dot = sum(left.get(key, 0.0) * right.get(key, 0.0) for key in keys)
    left_norm = math.sqrt(sum(value * value for value in left.values()))
    right_norm = math.sqrt(sum(value * value for value in right.values()))
    if left_norm <= 1e-12 or right_norm <= 1e-12:
        return 0.0
    return max(0.0, min(1.0, 1.0 - dot / (left_norm * right_norm)))


def _yamnet_novelty(windows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    enriched = []
    previous: dict[str, float] | None = None
    for window in windows:
        current = {
            str(category.get("name", "")): float(category.get("score", 0.0))
            for category in window.get("topCategories", [])
            if category.get("name")
        }
        row = dict(window)
        row["semanticNovelty"] = (
            _cosine_distance(previous, current) if previous is not None else 0.0
        )
        enriched.append(row)
        previous = current
    return enriched


def build_timeline(
    yamnet_analysis: dict[str, Any],
    audio_analysis: dict[str, Any],
    video_analysis: dict[str, Any] | None = None,
    *,
    config: AdaptiveConfig | None = None,
) -> list[dict[str, Any]]:
    config = config or AdaptiveConfig()
    durations = [
        int(yamnet_analysis["durationMs"]),
        int(audio_analysis["durationMs"]),
    ]
    if video_analysis is not None:
        durations.append(int(video_analysis["durationMs"]))
    duration_ms = min(durations)
    yamnet = _yamnet_novelty(yamnet_analysis.get("yamnetWindows", []))
    audio = audio_analysis.get("audioWindows", [])
    video = video_analysis.get("videoWindows", []) if video_analysis else []
    timeline = []
    for start_ms in range(0, duration_ms, config.bin_ms):
        end_ms = min(duration_ms, start_ms + config.bin_ms)
        laughter = min(
            1.0, _max_feature(start_ms, end_ms, yamnet, "laughterScore") / 0.35
        )
        speech = _mean_feature(start_ms, end_ms, yamnet, "speechScore")
        music = _mean_feature(start_ms, end_ms, yamnet, "musicScore")
        reaction = _max_feature(start_ms, end_ms, yamnet, "reactionScore")
        semantic_novelty = _max_feature(
            start_ms, end_ms, yamnet, "semanticNovelty"
        )
        loudness = _mean_feature(start_ms, end_ms, audio, "relativeLoudness")
        loudness_rise = _max_feature(start_ms, end_ms, audio, "loudnessRise")
        spectral_flux = _mean_feature(start_ms, end_ms, audio, "normalizedFlux")
        motion = _mean_feature(start_ms, end_ms, video, "motionScore")
        content_change = _max_feature(start_ms, end_ms, video, "contentChange")
        scene_cut = _max_feature(start_ms, end_ms, video, "sceneCutScore")
        face_presence = _mean_feature(start_ms, end_ms, video, "facePresence")
        face_prominence = _max_feature(start_ms, end_ms, video, "faceProminence")
        face_change = _max_feature(start_ms, end_ms, video, "faceChange")
        visual_quality = (
            _mean_feature(start_ms, end_ms, video, "visualQuality")
            if video
            else 1.0
        )

        social_event = (
            0.45 * laughter
            + 0.12 * reaction
            + 0.12 * speech
            + 0.12 * loudness_rise
            + 0.09 * spectral_flux
            + 0.10 * semantic_novelty
        )
        # 배경음 사건 — 음악·TV·갑작스러운 소음처럼 사람 목소리가 아닌 소리가
        # 커지거나 바뀌는 구간. 음악 점수는 항의 하나일 뿐이고 나머지 0.55는
        # 음량 상승·스펙트럼 변화·의미 변화가 채운다. 실제로 이 가설이 이기는
        # 지점 대부분에는 음악이 없다.
        ambient_event = (
            0.45 * music
            + 0.18 * loudness_rise
            + 0.12 * spectral_flux
            + 0.10 * loudness
            + 0.15 * semantic_novelty
        )
        dialogue_event = (
            0.55 * speech
            + 0.30 * laughter
            + 0.15 * reaction
        )
        visual_event = (
            0.40 * motion
            + 0.20 * content_change
            + 0.15 * scene_cut
            + 0.15 * face_prominence
            + 0.10 * face_change
        )
        audio_event = max(social_event, ambient_event, 0.65 * dialogue_event)
        event_score = max(
            audio_event,
            0.25 * visual_event,
        )
        if video and visual_quality < 0.35:
            event_score *= 0.70 + 0.30 * visual_quality / 0.35
        event_score = min(1.0, event_score)
        continuity_score = max(
            speech,
            0.90 * music + 0.10 * loudness,
            0.60 * laughter + 0.40 * speech,
            0.20 * motion,
        )
        timeline.append(
            {
                "startMs": start_ms,
                "endMs": end_ms,
                "eventScore": round(event_score, 6),
                "continuityScore": round(continuity_score, 6),
                "socialEvent": round(social_event, 6),
                "ambientEvent": round(ambient_event, 6),
                "dialogueEvent": round(dialogue_event, 6),
                "visualEvent": round(visual_event, 6),
                "features": {
                    "laughter": round(laughter, 6),
                    "speech": round(speech, 6),
                    "music": round(music, 6),
                    "reaction": round(reaction, 6),
                    "loudness": round(loudness, 6),
                    "loudnessRise": round(loudness_rise, 6),
                    "spectralFlux": round(spectral_flux, 6),
                    "semanticNovelty": round(semantic_novelty, 6),
                    "motion": round(motion, 6),
                    "contentChange": round(content_change, 6),
                    "sceneCut": round(scene_cut, 6),
                    "facePresence": round(face_presence, 6),
                    "faceProminence": round(face_prominence, 6),
                    "faceChange": round(face_change, 6),
                    "visualQuality": round(visual_quality, 6),
                },
            }
        )
    return timeline


def _smooth(values: list[float], radius: int = 1) -> list[float]:
    smoothed = []
    for index in range(len(values)):
        start = max(0, index - radius)
        end = min(len(values), index + radius + 1)
        smoothed.append(sum(values[start:end]) / (end - start))
    return smoothed


def _boundary_candidates(
    yamnet_analysis: dict[str, Any],
    video_analysis: dict[str, Any] | None = None,
) -> list[tuple[int, float]]:
    duration_ms = int(yamnet_analysis["durationMs"])
    candidates: dict[int, float] = {0: 1.0, duration_ms: 1.0}
    for window in yamnet_analysis.get("yamnetWindows", []):
        if (
            float(window.get("speechScore", 1.0)) < 0.20
            and float(window.get("laughterScore", 0.0)) < 0.10
        ):
            for key in ("startMs", "endMs"):
                value = int(window[key])
                candidates[value] = max(candidates.get(value, 0.0), 0.65)
    if video_analysis is not None:
        for window in video_analysis.get("videoWindows", []):
            scene_cut = float(window.get("sceneCutScore", 0.0))
            if scene_cut < 0.55:
                continue
            value = int(window["startMs"])
            candidates[value] = max(
                candidates.get(value, 0.0), min(0.95, 0.70 + 0.25 * scene_cut)
            )
    return sorted(candidates.items())


def _snap_boundary(
    target_ms: int,
    candidates: list[tuple[int, float]],
    *,
    search_ms: int,
) -> int:
    nearby = [
        (timestamp, score)
        for timestamp, score in candidates
        if abs(timestamp - target_ms) <= search_ms
    ]
    if not nearby:
        return target_ms
    return max(
        nearby,
        key=lambda item: (
            item[1] - 0.20 * abs(item[0] - target_ms) / max(search_ms, 1),
            -abs(item[0] - target_ms),
        ),
    )[0]


def _ambient_motion_block(
    timeline: list[dict[str, Any]],
    seed_index: int,
    *,
    quiet_tolerance_bins: int = 8,
) -> tuple[int, int] | None:
    """Find the visible cause and resolution around a detected music event.

    A connection change can be visible long before music becomes loud.  Short
    inactive gaps are therefore bridged while looking for sustained motion on
    either side of the music seed.
    """

    def is_active(index: int) -> bool:
        row = timeline[index]
        features = row.get("features", {})
        return (
            float(features.get("music", 0.0)) >= 0.15
            or float(features.get("motion", 0.0)) >= 0.45
        )

    def find_edge(direction: int) -> int:
        index = seed_index
        last_active = seed_index
        quiet_bins = 0
        reached_timeline_edge = True
        while 0 <= index + direction < len(timeline):
            index += direction
            if is_active(index):
                last_active = index
                quiet_bins = 0
            else:
                quiet_bins += 1
                if quiet_bins >= quiet_tolerance_bins:
                    reached_timeline_edge = False
                    break
        if reached_timeline_edge and quiet_bins < quiet_tolerance_bins:
            return 0 if direction < 0 else len(timeline) - 1
        return last_active

    left = find_edge(-1)
    right = find_edge(1)
    if right <= left:
        return None
    rows = timeline[left : right + 1]
    music_bins = sum(
        float(row.get("features", {}).get("music", 0.0)) >= 0.15 for row in rows
    )
    motion_bins = sum(
        float(row.get("features", {}).get("motion", 0.0)) >= 0.45 for row in rows
    )
    if music_bins < 2 or motion_bins < 3:
        return None
    start_ms = max(0, int(timeline[left]["startMs"]) - 2_000)
    end_ms = int(timeline[right]["endMs"]) + 2_000
    end_ms = min(int(timeline[-1]["endMs"]), end_ms)
    return start_ms, end_ms


def select_adaptive_highlight(
    timeline: list[dict[str, Any]],
    yamnet_analysis: dict[str, Any],
    video_analysis: dict[str, Any] | None = None,
    *,
    config: AdaptiveConfig | None = None,
) -> dict[str, Any]:
    config = config or AdaptiveConfig()
    if not timeline:
        raise ValueError("timeline cannot be empty")
    event_scores = [float(row["eventScore"]) for row in timeline]
    smoothed = _smooth(event_scores)
    seed_index = max(range(len(timeline)), key=lambda index: (smoothed[index], index))
    peak_score = smoothed[seed_index]
    baseline_score = statistics.median(smoothed)
    keep_threshold = baseline_score + 0.40 * max(0.0, peak_score - baseline_score)
    keep_scores = [
        max(float(row["eventScore"]), 0.20 * float(row["continuityScore"]))
        for row in timeline
    ]
    seed = timeline[seed_index]
    event_type = max(
        ("social", float(seed["socialEvent"])),
        ("ambient", float(seed["ambientEvent"])),
        ("dialogue", 0.65 * float(seed["dialogueEvent"])),
        ("visual", 0.25 * float(seed.get("visualEvent", 0.0))),
        key=lambda item: item[1],
    )[0]

    def find_edge(direction: int) -> int:
        index = seed_index
        last_good = seed_index
        low_count = 0
        while 0 <= index + direction < len(timeline):
            index += direction
            start = min(index, index + direction * 2)
            end = max(index, index + direction * 2)
            lookahead = keep_scores[max(0, start) : min(len(timeline), end + 1)]
            lookahead_mean = sum(lookahead) / len(lookahead)
            good = (
                keep_scores[index] >= keep_threshold
                or lookahead_mean >= keep_threshold
            )
            if good:
                last_good = index
                low_count = 0
            else:
                low_count += 1
                if low_count >= config.low_tail_bins:
                    break
        return last_good

    left = find_edge(-1)
    right = find_edge(1)
    start_ms = int(timeline[left]["startMs"])
    end_ms = int(timeline[right]["endMs"])
    flow_expansion: str | None = None

    if event_type == "ambient":
        ambient_story = _ambient_motion_block(timeline, seed_index)
        if ambient_story is not None:
            start_ms, end_ms = ambient_story
            flow_expansion = "ambient-motion-episode"

    event_minimum_ms = 10_000 if event_type == "ambient" else 15_000
    minimum_duration_ms = max(config.minimum_duration_ms, event_minimum_ms)
    if end_ms - start_ms < minimum_duration_ms:
        missing = minimum_duration_ms - (end_ms - start_ms)
        start_ms = max(0, start_ms - missing // 2)
        end_ms = min(int(yamnet_analysis["durationMs"]), end_ms + missing - missing // 2)
    if end_ms - start_ms > config.maximum_duration_ms:
        seed_center = (
            int(timeline[seed_index]["startMs"]) + int(timeline[seed_index]["endMs"])
        ) // 2
        start_ms = max(0, seed_center - config.maximum_duration_ms // 2)
        end_ms = min(
            int(yamnet_analysis["durationMs"]), start_ms + config.maximum_duration_ms
        )
        start_ms = max(0, end_ms - config.maximum_duration_ms)

    boundaries = _boundary_candidates(yamnet_analysis, video_analysis)
    start_ms = _snap_boundary(
        start_ms, boundaries, search_ms=config.boundary_search_ms
    )
    end_ms = _snap_boundary(end_ms, boundaries, search_ms=config.boundary_search_ms)
    if end_ms <= start_ms:
        raise RuntimeError("adaptive selector produced an invalid interval")

    return {
        "startMs": start_ms,
        "endMs": end_ms,
        "durationMs": end_ms - start_ms,
        "seedStartMs": int(seed["startMs"]),
        "seedEndMs": int(seed["endMs"]),
        "peakScore": round(peak_score, 6),
        "baselineScore": round(baseline_score, 6),
        "keepThreshold": round(keep_threshold, 6),
        "eventType": event_type,
        "flowExpansion": flow_expansion,
        "confidence": round(
            min(1.0, max(0.0, peak_score - baseline_score) / 0.30), 6
        ),
    }
