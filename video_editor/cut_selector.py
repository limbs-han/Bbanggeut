"""Select a natural, continuous highlight interval from scored segments."""

from __future__ import annotations

from collections.abc import Iterable

from .models import CutCandidate, CutSelection, ScoreSegment, SelectorConfig


class CutSelector:
    """Deterministic selector aligned to STT/VAD segment boundaries."""

    def __init__(self, config: SelectorConfig | None = None) -> None:
        self.config = config or SelectorConfig()

    def select(
        self,
        *,
        duration_ms: int,
        anchor_start_ms: int,
        anchor_end_ms: int,
        segments: Iterable[ScoreSegment],
    ) -> CutSelection:
        self._validate_request(duration_ms, anchor_start_ms, anchor_end_ms)
        normalized = self._normalize_segments(duration_ms, segments)

        if duration_ms <= self.config.min_duration_ms:
            return CutSelection(
                start_ms=0,
                end_ms=duration_ms,
                score=self._content_score(0, duration_ms, normalized),
                reason="source_shorter_than_minimum",
                candidate_count=1,
                used_fallback=True,
            )

        strict_context = self._context_is_possible(
            duration_ms, anchor_start_ms, anchor_end_ms
        )
        candidates = self._candidates(
            duration_ms=duration_ms,
            anchor_start_ms=anchor_start_ms,
            anchor_end_ms=anchor_end_ms,
            segments=normalized,
            require_context=strict_context,
        )
        if not candidates and strict_context:
            candidates = self._candidates(
                duration_ms=duration_ms,
                anchor_start_ms=anchor_start_ms,
                anchor_end_ms=anchor_end_ms,
                segments=normalized,
                require_context=False,
            )

        if not candidates:
            return self._fallback(duration_ms, anchor_start_ms, anchor_end_ms, normalized)

        # Stable tie breaking: score, safer combined boundary, shorter, earlier.
        winner = max(
            candidates,
            key=lambda candidate: (
                round(candidate.score, 12),
                round(
                    candidate.start_boundary_score + candidate.end_boundary_score, 12
                ),
                -candidate.duration_ms,
                -candidate.start_ms,
            ),
        )
        return CutSelection(
            start_ms=winner.start_ms,
            end_ms=winner.end_ms,
            score=winner.score,
            reason="highest_mean_quality_on_safe_boundaries",
            candidate_count=len(candidates),
        )

    def _candidates(
        self,
        *,
        duration_ms: int,
        anchor_start_ms: int,
        anchor_end_ms: int,
        segments: list[ScoreSegment],
        require_context: bool,
    ) -> list[CutCandidate]:
        starts = sorted({0, *(segment.start_ms for segment in segments)})
        ends = sorted({duration_ms, *(segment.end_ms for segment in segments)})
        candidates: list[CutCandidate] = []

        for start_ms in starts:
            for end_ms in ends:
                duration = end_ms - start_ms
                if not self.config.min_duration_ms <= duration <= self.config.max_duration_ms:
                    continue
                if start_ms > anchor_start_ms or end_ms < anchor_end_ms:
                    continue
                if require_context and not self._has_context(
                    start_ms, end_ms, anchor_start_ms, anchor_end_ms
                ):
                    continue
                candidates.append(
                    self._score_candidate(
                        start_ms,
                        end_ms,
                        anchor_start_ms,
                        anchor_end_ms,
                        segments,
                    )
                )
        return candidates

    def _score_candidate(
        self,
        start_ms: int,
        end_ms: int,
        anchor_start_ms: int,
        anchor_end_ms: int,
        segments: list[ScoreSegment],
    ) -> CutCandidate:
        content_score = self._content_score(start_ms, end_ms, segments)
        start_boundary_score = self._boundary_score(start_ms, segments, is_start=True)
        end_boundary_score = self._boundary_score(end_ms, segments, is_start=False)
        context_score = self._context_score(
            start_ms, end_ms, anchor_start_ms, anchor_end_ms
        )
        extra_seconds = (end_ms - start_ms - self.config.min_duration_ms) / 1000.0
        score = (
            self.config.content_weight * content_score
            + self.config.start_boundary_weight * start_boundary_score
            + self.config.end_boundary_weight * end_boundary_score
            + self.config.context_weight * context_score
            - self.config.extra_second_penalty * extra_seconds
        )
        return CutCandidate(
            start_ms=start_ms,
            end_ms=end_ms,
            score=score,
            content_score=content_score,
            start_boundary_score=start_boundary_score,
            end_boundary_score=end_boundary_score,
            context_score=context_score,
        )

    @staticmethod
    def _content_score(
        start_ms: int, end_ms: int, segments: list[ScoreSegment]
    ) -> float:
        if end_ms <= start_ms:
            return 0.0
        weighted_score = 0.0
        for segment in segments:
            overlap_ms = max(
                0, min(end_ms, segment.end_ms) - max(start_ms, segment.start_ms)
            )
            weighted_score += overlap_ms * segment.edit_score
        # Gaps intentionally score zero: analysis adapters should cover the full
        # timeline, and an unexplained gap must not improve a candidate.
        return weighted_score / (end_ms - start_ms)

    @staticmethod
    def _boundary_score(
        timestamp_ms: int, segments: list[ScoreSegment], *, is_start: bool
    ) -> float:
        matching: list[float] = []
        for segment in segments:
            if is_start and segment.start_ms == timestamp_ms:
                matching.append(segment.start_boundary_score)
            elif not is_start and segment.end_ms == timestamp_ms:
                matching.append(segment.end_boundary_score)
        if matching:
            return max(matching)
        # Source boundaries are naturally safe; all other synthetic boundaries
        # are deliberately conservative.
        if timestamp_ms == 0:
            return 1.0
        return 0.0

    def _context_score(
        self,
        start_ms: int,
        end_ms: int,
        anchor_start_ms: int,
        anchor_end_ms: int,
    ) -> float:
        before_ratio = 1.0
        if self.config.context_before_ms:
            before_ratio = min(
                1.0,
                (anchor_start_ms - start_ms) / self.config.context_before_ms,
            )
        after_ratio = 1.0
        if self.config.context_after_ms:
            after_ratio = min(
                1.0,
                (end_ms - anchor_end_ms) / self.config.context_after_ms,
            )
        return max(0.0, (before_ratio + after_ratio) / 2.0)

    def _context_is_possible(
        self, duration_ms: int, anchor_start_ms: int, anchor_end_ms: int
    ) -> bool:
        needed = (
            anchor_end_ms
            - anchor_start_ms
            + self.config.context_before_ms
            + self.config.context_after_ms
        )
        return (
            needed <= self.config.max_duration_ms
            and anchor_start_ms >= self.config.context_before_ms
            and duration_ms - anchor_end_ms >= self.config.context_after_ms
        )

    def _has_context(
        self,
        start_ms: int,
        end_ms: int,
        anchor_start_ms: int,
        anchor_end_ms: int,
    ) -> bool:
        return (
            anchor_start_ms - start_ms >= self.config.context_before_ms
            and end_ms - anchor_end_ms >= self.config.context_after_ms
        )

    def _fallback(
        self,
        duration_ms: int,
        anchor_start_ms: int,
        anchor_end_ms: int,
        segments: list[ScoreSegment],
    ) -> CutSelection:
        target_ms = min(self.config.min_duration_ms, duration_ms)
        anchor_center = (anchor_start_ms + anchor_end_ms) // 2
        start_ms = max(0, min(anchor_center - target_ms // 2, duration_ms - target_ms))
        end_ms = start_ms + target_ms
        return CutSelection(
            start_ms=start_ms,
            end_ms=end_ms,
            score=self._content_score(start_ms, end_ms, segments),
            reason="fixed_window_fallback_no_safe_candidate",
            candidate_count=0,
            used_fallback=True,
        )

    @staticmethod
    def _normalize_segments(
        duration_ms: int, segments: Iterable[ScoreSegment]
    ) -> list[ScoreSegment]:
        normalized = sorted(segments, key=lambda segment: (segment.start_ms, segment.end_ms))
        previous_end_ms = 0
        for segment in normalized:
            if segment.end_ms > duration_ms:
                raise ValueError("segment end_ms exceeds video duration")
            if segment.start_ms < previous_end_ms:
                raise ValueError("score segments must not overlap")
            previous_end_ms = segment.end_ms
        return normalized

    @staticmethod
    def _validate_request(
        duration_ms: int, anchor_start_ms: int, anchor_end_ms: int
    ) -> None:
        if duration_ms <= 0:
            raise ValueError("duration_ms must be positive")
        if not 0 <= anchor_start_ms <= anchor_end_ms <= duration_ms:
            raise ValueError("anchor interval must be inside the video duration")


def select_cut(
    *,
    duration_ms: int,
    anchor_start_ms: int,
    anchor_end_ms: int,
    segments: Iterable[ScoreSegment],
    config: SelectorConfig | None = None,
) -> CutSelection:
    """Convenience wrapper for one-off selection."""

    return CutSelector(config).select(
        duration_ms=duration_ms,
        anchor_start_ms=anchor_start_ms,
        anchor_end_ms=anchor_end_ms,
        segments=segments,
    )
