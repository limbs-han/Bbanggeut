"""Hardware-independent tests for rolling segment event clips."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from io import BytesIO
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from segment_clip_uploader import (
    SegmentCoverageError,
    Trigger,
    clip_interval,
    group_triggers,
    http_error_body,
    is_retryable_http_status,
    parse_segment,
    retry_delay,
    run,
    safe_endpoint,
    select_completed_segments,
    unhandled_triggers,
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

    def test_http_error_diagnostics_redact_query_and_bound_body(self) -> None:
        error = HTTPError(
            "https://storage.example/video?secret=signed-value",
            409,
            "Conflict",
            {},
            BytesIO(b'{"message":"duplicate event"}'),
        )

        self.assertEqual(
            safe_endpoint(error.url),
            "https://storage.example/video",
        )
        self.assertEqual(
            http_error_body(error),
            '{"message":"duplicate event"}',
        )

    def test_http_retry_policy(self) -> None:
        self.assertFalse(is_retryable_http_status(409))
        self.assertFalse(is_retryable_http_status(422))
        self.assertTrue(is_retryable_http_status(429))
        self.assertTrue(is_retryable_http_status(503))

    def test_retry_delay_is_exponential_and_capped(self) -> None:
        self.assertEqual(retry_delay(1, 5, 300), 5)
        self.assertEqual(retry_delay(2, 5, 300), 10)
        self.assertEqual(retry_delay(20, 5, 300), 300)

    def test_blocked_trigger_is_not_scanned_again(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event_dir = root / "events"
            recording_dir = root / "recordings"
            event_dir.mkdir()
            recording_dir.mkdir()
            (recording_dir / ".homecam-recordings").touch()
            item = trigger("blocked", 0)
            trigger_path = event_dir / item.path.name
            trigger_path.write_text(
                json.dumps(
                    {
                        "eventId": "blocked",
                        "occurredAt": "2026-07-23T12:00:00.000Z",
                        "preSeconds": 60,
                        "postSeconds": 60,
                    }
                ),
                encoding="utf-8",
            )
            args = SimpleNamespace(
                event_dir=event_dir,
                recording_dir=recording_dir,
                device_token="test-token",
                poll_seconds=1.0,
                segment_seconds=60.0,
                segment_finalize_seconds=3.0,
                retry_initial_seconds=5.0,
                retry_max_seconds=300.0,
                merge_gap_seconds=30.0,
            )
            error = HTTPError(
                "https://api.example/videos/upload-url?secret=value",
                409,
                "Conflict",
                {},
                BytesIO(b'{"message":"conflict"}'),
            )

            with (
                patch(
                    "segment_clip_uploader.process_group",
                    side_effect=error,
                ),
                patch(
                    "segment_clip_uploader.time.sleep",
                    side_effect=KeyboardInterrupt,
                ),
                self.assertRaises(KeyboardInterrupt),
            ):
                run(args)

            self.assertEqual(unhandled_triggers(event_dir), [])
            marker = json.loads(
                (event_dir / "blocked.upload-blocked.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(marker["httpStatus"], 409)
            self.assertFalse(marker["retryable"])


if __name__ == "__main__":
    unittest.main()
