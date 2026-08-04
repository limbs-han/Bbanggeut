"""Data models for deterministic cut selection.

The selector deliberately consumes model-independent score segments. STT, VAD,
YAMNet, and vision adapters can evolve without changing the selection contract.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


def _unit_interval(name: str, value: float) -> None:
    if not 0.0 <= value <= 1.0:
        raise ValueError(f"{name} must be between 0.0 and 1.0")


@dataclass(frozen=True, slots=True)
class ScoreSegment:
    """A scored half-open interval on the source-video timeline."""

    start_ms: int
    end_ms: int
    edit_score: float
    start_boundary_score: float = 0.5
    end_boundary_score: float = 0.5
    text: str = ""
    features: dict[str, float] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.start_ms < 0:
            raise ValueError("segment start_ms must be non-negative")
        if self.end_ms <= self.start_ms:
            raise ValueError("segment end_ms must be greater than start_ms")
        _unit_interval("edit_score", self.edit_score)
        _unit_interval("start_boundary_score", self.start_boundary_score)
        _unit_interval("end_boundary_score", self.end_boundary_score)

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "ScoreSegment":
        return cls(
            start_ms=int(value["startMs"]),
            end_ms=int(value["endMs"]),
            edit_score=float(value["editScore"]),
            start_boundary_score=float(value.get("startBoundaryScore", 0.5)),
            end_boundary_score=float(value.get("endBoundaryScore", 0.5)),
            text=str(value.get("text", "")),
            features={
                str(name): float(score)
                for name, score in value.get("features", {}).items()
            },
        )


@dataclass(frozen=True, slots=True)
class SelectorConfig:
    min_duration_ms: int = 45_000
    max_duration_ms: int = 65_000
    context_before_ms: int = 10_000
    context_after_ms: int = 10_000
    content_weight: float = 0.72
    start_boundary_weight: float = 0.12
    end_boundary_weight: float = 0.12
    context_weight: float = 0.04
    extra_second_penalty: float = 0.001

    def __post_init__(self) -> None:
        if self.min_duration_ms <= 0:
            raise ValueError("min_duration_ms must be positive")
        if self.max_duration_ms < self.min_duration_ms:
            raise ValueError("max_duration_ms must be at least min_duration_ms")
        if self.context_before_ms < 0 or self.context_after_ms < 0:
            raise ValueError("context durations must be non-negative")
        if self.extra_second_penalty < 0:
            raise ValueError("extra_second_penalty must be non-negative")
        total_weight = (
            self.content_weight
            + self.start_boundary_weight
            + self.end_boundary_weight
            + self.context_weight
        )
        if abs(total_weight - 1.0) > 1e-9:
            raise ValueError("selector score weights must sum to 1.0")


@dataclass(frozen=True, slots=True)
class CutCandidate:
    start_ms: int
    end_ms: int
    score: float
    content_score: float
    start_boundary_score: float
    end_boundary_score: float
    context_score: float

    @property
    def duration_ms(self) -> int:
        return self.end_ms - self.start_ms


@dataclass(frozen=True, slots=True)
class CutSelection:
    start_ms: int
    end_ms: int
    score: float
    reason: str
    candidate_count: int
    used_fallback: bool = False

    @property
    def duration_ms(self) -> int:
        return self.end_ms - self.start_ms

    def to_dict(self) -> dict[str, Any]:
        return {
            "startMs": self.start_ms,
            "endMs": self.end_ms,
            "durationMs": self.duration_ms,
            "score": round(self.score, 6),
            "reason": self.reason,
            "candidateCount": self.candidate_count,
            "usedFallback": self.used_fallback,
        }
