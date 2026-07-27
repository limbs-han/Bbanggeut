"""Pure-Python helpers for aggregating YAMNet laughter scores."""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Iterable, Sequence


SCORE_AGGREGATIONS = ("max", "mean", "p90")


@dataclass(frozen=True)
class LaughterScoreSummary:
    selected_aggregation: str
    selected_score: float
    selected_class: str
    max_score: float
    max_class: str
    mean_score: float
    mean_class: str
    p90_score: float
    p90_class: str


def percentile(values: Sequence[float], quantile: float) -> float:
    """Return a linearly interpolated percentile for a non-empty sequence."""

    if not values:
        raise ValueError("values cannot be empty")
    if not 0.0 <= quantile <= 1.0:
        raise ValueError("quantile must be between 0 and 1")

    ordered = sorted(float(value) for value in values)
    if len(ordered) == 1:
        return ordered[0]

    position = (len(ordered) - 1) * quantile
    lower_index = math.floor(position)
    upper_index = math.ceil(position)
    if lower_index == upper_index:
        return ordered[lower_index]

    fraction = position - lower_index
    return (
        ordered[lower_index] * (1.0 - fraction)
        + ordered[upper_index] * fraction
    )


def summarize_laughter_scores(
    rows: Iterable[Iterable[float]],
    class_names: Sequence[str],
    selected_aggregation: str,
) -> LaughterScoreSummary:
    """Summarize per-patch scores for the supplied laughter classes."""

    if selected_aggregation not in SCORE_AGGREGATIONS:
        raise ValueError(
            f"selected_aggregation must be one of {SCORE_AGGREGATIONS}"
        )
    names = tuple(class_names)
    if not names:
        raise ValueError("class_names cannot be empty")

    matrix = [tuple(float(value) for value in row) for row in rows]
    if not matrix:
        raise ValueError("score rows cannot be empty")
    if any(len(row) != len(names) for row in matrix):
        raise ValueError("every score row must match class_names")

    columns = tuple(zip(*matrix))
    metrics: dict[str, tuple[float, ...]] = {
        "max": tuple(max(column) for column in columns),
        "mean": tuple(sum(column) / len(column) for column in columns),
        "p90": tuple(percentile(column, 0.90) for column in columns),
    }

    def best(aggregation: str) -> tuple[float, str]:
        values = metrics[aggregation]
        index = max(range(len(values)), key=values.__getitem__)
        return values[index], names[index]

    selected_score, selected_class = best(selected_aggregation)
    max_score, max_class = best("max")
    mean_score, mean_class = best("mean")
    p90_score, p90_class = best("p90")
    return LaughterScoreSummary(
        selected_aggregation=selected_aggregation,
        selected_score=selected_score,
        selected_class=selected_class,
        max_score=max_score,
        max_class=max_class,
        mean_score=mean_score,
        mean_class=mean_class,
        p90_score=p90_score,
        p90_class=p90_class,
    )
