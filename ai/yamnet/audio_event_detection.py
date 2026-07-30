"""Pure state machines and text matching for advanced audio events."""

from __future__ import annotations

from dataclasses import dataclass
from difflib import SequenceMatcher
import math
import re
from typing import Iterable


CLAP_CLASS_KEYWORDS = (
    "clapping",
    "applause",
)


def find_class_indices(
    class_names: Iterable[str],
    keywords: Iterable[str],
) -> list[int]:
    """Return class indexes whose case-folded name contains a keyword."""

    normalized_keywords = tuple(
        keyword.strip().casefold()
        for keyword in keywords
        if keyword.strip()
    )
    if not normalized_keywords:
        raise ValueError("keywords cannot be empty")

    return [
        index
        for index, class_name in enumerate(class_names)
        if any(
            keyword in class_name.casefold()
            for keyword in normalized_keywords
        )
    ]


def count_impulsive_onsets(
    samples: Iterable[float],
    sample_rate: int,
    *,
    frame_seconds: float = 0.02,
    hop_seconds: float = 0.01,
    absolute_threshold: float = 0.02,
    relative_threshold: float = 4.0,
    refractory_seconds: float = 0.12,
) -> int:
    """Count separated high-energy attacks for clap gating.

    This is intentionally model-independent. A YAMNet clap classification must
    still be present, so speech transients alone do not create an event.
    """

    if sample_rate <= 0:
        raise ValueError("sample_rate must be positive")
    if frame_seconds <= 0 or hop_seconds <= 0:
        raise ValueError("frame_seconds and hop_seconds must be positive")
    if absolute_threshold < 0 or relative_threshold <= 1:
        raise ValueError("invalid onset threshold")
    if refractory_seconds < 0:
        raise ValueError("refractory_seconds cannot be negative")

    values = tuple(float(value) for value in samples)
    frame_size = max(1, int(round(sample_rate * frame_seconds)))
    hop_size = max(1, int(round(sample_rate * hop_seconds)))
    if len(values) < frame_size:
        return 0

    energies: list[float] = []
    for start in range(0, len(values) - frame_size + 1, hop_size):
        frame = values[start : start + frame_size]
        energies.append(
            math.sqrt(sum(value * value for value in frame) / len(frame))
        )
    if not energies:
        return 0

    ordered = sorted(energies)
    noise_floor = ordered[min(len(ordered) - 1, len(ordered) // 4)]
    threshold = max(absolute_threshold, noise_floor * relative_threshold)
    refractory_frames = max(
        1,
        int(math.ceil(refractory_seconds / hop_seconds)),
    )
    count = 0
    last_onset = -refractory_frames
    was_above = False
    for index, energy in enumerate(energies):
        is_above = energy >= threshold
        if (
            is_above
            and not was_above
            and index - last_onset >= refractory_frames
        ):
            count += 1
            last_onset = index
        was_above = is_above
    return count


@dataclass(frozen=True)
class ClapDetection:
    """A consecutive-clap decision emitted by the state machine."""

    score: float
    positive_windows: int
    active_seconds: float
    onset_count: int


class ConsecutiveClapDetector:
    """Require sustained clap classifications instead of a single impulse.

    YAMNet works on overlapping audio windows. Requiring multiple positive
    windows plus a minimum active duration rejects most isolated impacts while
    retaining a configurable response for repeated claps.
    """

    def __init__(
        self,
        *,
        threshold: float,
        required_windows: int,
        minimum_active_seconds: float,
        maximum_gap_seconds: float,
        cooldown_seconds: float,
        required_onsets: int = 2,
    ) -> None:
        if not 0.0 <= threshold <= 1.0:
            raise ValueError("threshold must be between 0 and 1")
        if required_windows < 2:
            raise ValueError("required_windows must be at least 2")
        if minimum_active_seconds < 0:
            raise ValueError("minimum_active_seconds cannot be negative")
        if maximum_gap_seconds <= 0:
            raise ValueError("maximum_gap_seconds must be positive")
        if cooldown_seconds < 0:
            raise ValueError("cooldown_seconds cannot be negative")
        if required_onsets < 2:
            raise ValueError("required_onsets must be at least 2")

        self.threshold = threshold
        self.required_windows = required_windows
        self.minimum_active_seconds = minimum_active_seconds
        self.maximum_gap_seconds = maximum_gap_seconds
        self.cooldown_seconds = cooldown_seconds
        self.required_onsets = required_onsets

        self._positive_windows = 0
        self._active_started_at: float | None = None
        self._last_positive_at: float | None = None
        self._last_observed_at: float | None = None
        self._last_trigger_at = float("-inf")

    @property
    def positive_windows(self) -> int:
        return self._positive_windows

    def reset(self) -> None:
        self._positive_windows = 0
        self._active_started_at = None
        self._last_positive_at = None

    def observe(
        self,
        score: float,
        observed_at: float,
        onset_count: int,
    ) -> ClapDetection | None:
        """Consume one aggregated YAMNet score and optionally emit a decision."""

        if not math.isfinite(score) or not 0.0 <= score <= 1.0:
            raise ValueError("score must be a finite value between 0 and 1")
        if not math.isfinite(observed_at):
            raise ValueError("observed_at must be finite")
        if onset_count < 0:
            raise ValueError("onset_count cannot be negative")
        if (
            self._last_observed_at is not None
            and observed_at < self._last_observed_at
        ):
            raise ValueError("observed_at must be monotonic")
        self._last_observed_at = observed_at

        if score < self.threshold or onset_count < self.required_onsets:
            self.reset()
            return None

        if (
            self._last_positive_at is None
            or observed_at - self._last_positive_at
            > self.maximum_gap_seconds
        ):
            self._positive_windows = 1
            self._active_started_at = observed_at
        else:
            self._positive_windows += 1
        self._last_positive_at = observed_at

        active_started_at = self._active_started_at
        if active_started_at is None:
            return None
        active_seconds = observed_at - active_started_at
        if self._positive_windows < self.required_windows:
            return None
        if active_seconds < self.minimum_active_seconds:
            return None
        if observed_at - self._last_trigger_at < self.cooldown_seconds:
            return None

        detection = ClapDetection(
            score=score,
            positive_windows=self._positive_windows,
            active_seconds=active_seconds,
            onset_count=onset_count,
        )
        self._last_trigger_at = observed_at
        self.reset()
        return detection


_NON_WORD = re.compile(r"[^\w]+", flags=re.UNICODE)


def normalize_wake_phrase(value: str) -> str:
    """Normalize an ASR transcript while preserving Korean and other letters."""

    return _NON_WORD.sub("", value.casefold()).replace("_", "")


def wake_phrase_similarity(phrase: str, transcript: str) -> float:
    """Return the best compact-text similarity for a phrase in a transcript."""

    normalized_phrase = normalize_wake_phrase(phrase)
    normalized_transcript = normalize_wake_phrase(transcript)
    if not normalized_phrase:
        raise ValueError("phrase must contain at least one letter or number")
    if not normalized_transcript:
        return 0.0
    if normalized_phrase in normalized_transcript:
        return 1.0

    phrase_length = len(normalized_phrase)
    minimum_length = max(1, phrase_length - 2)
    maximum_length = min(
        len(normalized_transcript),
        phrase_length + 2,
    )
    best = 0.0
    for window_length in range(minimum_length, maximum_length + 1):
        for start in range(
            0,
            len(normalized_transcript) - window_length + 1,
        ):
            candidate = normalized_transcript[start : start + window_length]
            best = max(
                best,
                SequenceMatcher(
                    None,
                    normalized_phrase,
                    candidate,
                ).ratio(),
            )
    return best


@dataclass(frozen=True)
class WakeNameDetection:
    phrase: str
    transcript: str
    confidence: float


class WakeNameDetector:
    """Match speaker-independent local ASR transcripts against one phrase."""

    def __init__(
        self,
        *,
        phrase: str,
        threshold: float = 0.82,
        cooldown_seconds: float = 12.0,
    ) -> None:
        if not normalize_wake_phrase(phrase):
            raise ValueError("phrase must contain at least one letter or number")
        if not 0.0 <= threshold <= 1.0:
            raise ValueError("threshold must be between 0 and 1")
        if cooldown_seconds < 0:
            raise ValueError("cooldown_seconds cannot be negative")

        self.phrase = phrase.strip()
        self.threshold = threshold
        self.cooldown_seconds = cooldown_seconds
        self._last_observed_at: float | None = None
        self._last_trigger_at = float("-inf")

    def observe(
        self,
        transcript: str,
        observed_at: float,
    ) -> WakeNameDetection | None:
        if not math.isfinite(observed_at):
            raise ValueError("observed_at must be finite")
        if (
            self._last_observed_at is not None
            and observed_at < self._last_observed_at
        ):
            raise ValueError("observed_at must be monotonic")
        self._last_observed_at = observed_at

        confidence = wake_phrase_similarity(self.phrase, transcript)
        if confidence < self.threshold:
            return None
        if observed_at - self._last_trigger_at < self.cooldown_seconds:
            return None

        self._last_trigger_at = observed_at
        return WakeNameDetection(
            phrase=self.phrase,
            transcript=transcript.strip(),
            confidence=confidence,
        )
