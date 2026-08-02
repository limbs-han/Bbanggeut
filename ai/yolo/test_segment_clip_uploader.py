"""Hardware-independent tests for rolling segment event clips."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from io import BytesIO
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from segment_clip_uploader import (
    SegmentCoverageError,
    Trigger,
    canonical_trigger,
    clip_interval,
    event_title,
    event_types,
    group_triggers,
    http_error_body,
    is_retryable_http_status,
    keyframe_offset,
    parse_trigger,
    parse_segment,
    retry_delay,
    run,
    safe_endpoint,
    select_completed_segments,
    unhandled_triggers,
    upload_group,
)


UTC = timezone.utc


def trigger(
    name: str,
    second: int,
    event_type: str = "LAUGHTER",
) -> Trigger:
    return Trigger(
        path=Path(f"{name}.trigger.json"),
        event_id=name,
        occurred_at=datetime(2026, 7, 23, 12, 0, second, tzinfo=UTC),
        pre_seconds=60,
        post_seconds=60,
        event_type=event_type,
    )


class SegmentClipUploaderTests(unittest.TestCase):
    def test_parses_versioned_audio_event_type(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "clap-1.trigger.json"
            path.write_text(
                json.dumps(
                    {
                        "schemaVersion": "1.1",
                        "eventId": "clap-1",
                        "type": "CLAP",
                        "occurredAt": "2026-07-30T00:00:00.000Z",
                        "preSeconds": 60,
                        "postSeconds": 60,
                    }
                ),
                encoding="utf-8",
            )

            parsed = parse_trigger(path)

            self.assertEqual(parsed.event_type, "CLAP")

    def test_rejects_unknown_audio_event_type(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "noise-1.trigger.json"
            path.write_text(
                json.dumps(
                    {
                        "eventId": "noise-1",
                        "type": "NOISE",
                        "occurredAt": "2026-07-30T00:00:00.000Z",
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaises(ValueError):
                parse_trigger(path)

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

    def test_different_audio_event_types_are_not_merged(self) -> None:
        items = [
            trigger("laugh-first", 0, "LAUGHTER"),
            trigger("clap", 10, "CLAP"),
            trigger("laugh-second", 20, "LAUGHTER"),
        ]

        groups = group_triggers(items, 30)

        self.assertEqual(
            [[item.event_id for item in group] for group in groups],
            [["laugh-first", "laugh-second"], ["clap"]],
        )

    def test_laughter_and_clap_within_five_seconds_share_one_event(self) -> None:
        items = [
            trigger("clap-first", 0, "CLAP"),
            trigger("laugh-second", 4, "LAUGHTER"),
        ]

        groups = group_triggers(items, 30, 5)

        self.assertEqual(len(groups), 1)
        self.assertEqual(
            [item.event_id for item in groups[0]],
            ["clap-first", "laugh-second"],
        )
        self.assertEqual(
            canonical_trigger(groups[0]).event_id,
            "laugh-second",
        )
        self.assertEqual(event_types(groups[0]), ("LAUGHTER", "CLAP"))
        self.assertEqual(
            event_title(groups[0]),
            "웃음과 박수가 함께 포착됐어요",
        )

    def test_laughter_and_clap_outside_five_seconds_stay_separate(self) -> None:
        groups = group_triggers(
            [
                trigger("laugh", 0, "LAUGHTER"),
                trigger("clap", 6, "CLAP"),
            ],
            30,
            5,
        )

        self.assertEqual(
            [[item.event_id for item in group] for group in groups],
            [["laugh"], ["clap"]],
        )

    def test_wake_word_does_not_cross_merge_with_laughter(self) -> None:
        groups = group_triggers(
            [
                trigger("laugh", 0, "LAUGHTER"),
                trigger("wake", 1, "WAKE_WORD"),
            ],
            30,
            5,
        )

        self.assertEqual(
            [[item.event_id for item in group] for group in groups],
            [["laugh"], ["wake"]],
        )

    def test_mixed_event_requests_one_laughter_upload_with_mixed_title(self) -> None:
        group = [
            trigger("clap-first", 0, "CLAP"),
            trigger("laugh-second", 4, "LAUGHTER"),
        ]

        with tempfile.TemporaryDirectory() as temporary_directory:
            event_dir = Path(temporary_directory)
            output_path = event_dir / "laugh-second.mp4"
            output_path.write_bytes(b"mixed-event-video")
            args = SimpleNamespace(
                event_dir=event_dir,
                api_base_url="https://api.example.test",
                device_token="device-token",
            )

            with patch(
                "segment_clip_uploader.request_json",
                return_value=(
                    {
                        "alreadyCompleted": True,
                        "videoId": "video-1",
                    },
                    {},
                ),
            ) as request:
                response = upload_group(
                    args,
                    group,
                    datetime(2026, 7, 23, 11, 59, 0, tzinfo=UTC),
                    datetime(2026, 7, 23, 12, 1, 4, tzinfo=UTC),
                    output_path,
                )

            self.assertEqual(response["videoId"], "video-1")
            request.assert_called_once()
            request_payload = request.call_args.args[3]
            self.assertEqual(request_payload["sourceEventId"], "laugh-second")
            self.assertEqual(request_payload["triggerType"], "LAUGHTER")
            self.assertEqual(
                request_payload["title"],
                "웃음과 박수가 함께 포착됐어요",
            )
            self.assertEqual(
                request_payload["eventTypes"],
                ["LAUGHTER", "CLAP"],
            )

            status = json.loads(
                (event_dir / "laugh-second.upload-status.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(status["canonicalEventId"], "laugh-second")
            self.assertEqual(status["mergedEventIds"], ["clap-first"])
            self.assertEqual(status["eventTypes"], ["LAUGHTER", "CLAP"])

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
                cross_type_merge_gap_seconds=5.0,
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
            status = json.loads(
                (event_dir / "blocked.upload-status.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(status["status"], "BLOCKED")
            self.assertEqual(status["httpStatus"], 409)

    def test_cut_point_snaps_back_to_the_previous_keyframe(self) -> None:
        # 30 fps with a 1 s GOP, phase-shifted like a real MPEG-TS segment.
        probe_output = "".join(
            f"{index / 30 + 0.021333:.6f},{'K__' if index % 30 == 0 else '___'}\n"
            for index in range(0, 260)
        )
        with patch("segment_clip_uploader.subprocess.run") as runner:
            runner.return_value = SimpleNamespace(stdout=probe_output)
            snapped = keyframe_offset("/usr/bin/ffmpeg", Path("c.txt"), 7.4)
        # Audio can start anywhere, but video only resumes on a keyframe, so the
        # cut has to land on one or the clip opens with video trailing audio.
        self.assertAlmostEqual(snapped, 7.021333, places=6)
        self.assertLessEqual(snapped, 7.4)

    def test_cut_point_is_unchanged_when_it_already_sits_on_a_keyframe(self) -> None:
        with patch("segment_clip_uploader.subprocess.run") as runner:
            runner.return_value = SimpleNamespace(stdout="12.000000,K__\n")
            self.assertAlmostEqual(
                keyframe_offset("/usr/bin/ffmpeg", Path("c.txt"), 12.0),
                12.0,
                places=6,
            )

    def test_probe_failure_keeps_the_requested_cut_point(self) -> None:
        # A clip that is slightly out of sync still beats no clip at all.
        for failure in (OSError("ffprobe missing"), subprocess.TimeoutExpired("x", 1)):
            with self.subTest(failure=type(failure).__name__):
                with patch(
                    "segment_clip_uploader.subprocess.run",
                    side_effect=failure,
                ):
                    self.assertAlmostEqual(
                        keyframe_offset("/usr/bin/ffmpeg", Path("c.txt"), 41.75),
                        41.75,
                        places=6,
                    )

    def test_probe_without_keyframes_keeps_the_requested_cut_point(self) -> None:
        with patch("segment_clip_uploader.subprocess.run") as runner:
            runner.return_value = SimpleNamespace(stdout="3.000000,___\nbroken\n")
            self.assertAlmostEqual(
                keyframe_offset("/usr/bin/ffmpeg", Path("c.txt"), 9.5),
                9.5,
                places=6,
            )

    def test_zero_cut_point_skips_probing(self) -> None:
        with patch("segment_clip_uploader.subprocess.run") as runner:
            self.assertEqual(keyframe_offset("/usr/bin/ffmpeg", Path("c.txt"), 0.0), 0.0)
            runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
