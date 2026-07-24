"""Hardware-independent tests for rolling segment event clips."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
import unittest

from segment_clip_uploader import (
    SegmentCoverageError,
    Trigger,
    clip_interval,
    group_triggers,
    parse_segment,
    select_completed_segments,
)


UTC = timezone.utc


def trigger(name: str, second: int) -> Trigger:
    return Trigger(
        path=Path(f"{name}.trigger.json"),
        event_id=name,
        occurred_at=datetime(2026, 7, 23, 12, 0, second, tzinfo=UTC),
        pre_seconds=60,
        post_seconds=60,
    )


class SegmentClipUploaderTests(unittest.TestCase):
    def test_groups_consecutive_laughter_within_thirty_seconds(self) -> None:
        items = [
            trigger("first", 0),
            trigger("second", 20),
            trigger("third", 55),
        ]

        groups = group_triggers(items, 30)

        self.assertEqual(
            [[item.event_id for item in group] for group in groups],
            [["first", "second"], ["third"]],
        )

    def test_clip_uses_first_pre_and_last_post_boundaries(self) -> None:
        group = [trigger("first", 0), trigger("second", 20)]

        start, end = clip_interval(group)

        self.assertEqual(start, datetime(2026, 7, 23, 11, 59, 0, tzinfo=UTC))
        self.assertEqual(end, datetime(2026, 7, 23, 12, 1, 20, tzinfo=UTC))

    def test_segment_name_is_interpreted_as_utc(self) -> None:
        segment = parse_segment(Path("homecam-20260723T120000.ts"))

        self.assertEqual(
            segment.started_at,
            datetime(2026, 7, 23, 12, 0, 0, tzinfo=UTC),
        )

    def test_selects_only_completed_segments_covering_clip(self) -> None:
        paths = [
            Path("homecam-20260723T115800.ts"),
            Path("homecam-20260723T115900.ts"),
            Path("homecam-20260723T120000.ts"),
            Path("homecam-20260723T120100.ts"),
            Path("homecam-20260723T120200.ts"),
        ]

        selected = select_completed_segments(
            paths,
            datetime(2026, 7, 23, 11, 59, 10, tzinfo=UTC),
            datetime(2026, 7, 23, 12, 1, 10, tzinfo=UTC),
            60,
        )

        self.assertEqual(
            [segment.path.name for segment in selected],
            [
                "homecam-20260723T115900.ts",
                "homecam-20260723T120000.ts",
                "homecam-20260723T120100.ts",
            ],
        )

    def test_recording_gap_is_rejected(self) -> None:
        paths = [
            Path("homecam-20260723T115900.ts"),
            Path("homecam-20260723T120200.ts"),
            Path("homecam-20260723T120300.ts"),
        ]

        with self.assertRaises(SegmentCoverageError):
            select_completed_segments(
                paths,
                datetime(2026, 7, 23, 11, 59, 10, tzinfo=UTC),
                datetime(2026, 7, 23, 12, 0, 10, tzinfo=UTC),
                60,
            )


if __name__ == "__main__":
    unittest.main()
