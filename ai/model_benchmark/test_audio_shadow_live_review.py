import json
from pathlib import Path
import tempfile
import unittest

from audio_shadow_live_review import (
    CorrelationBuffer,
    Detection,
    DurableJsonlWriter,
    JsonlFollower,
    ReviewCandidate,
    build_manual_miss_record,
    build_review_record,
    detections_from_shadow,
    detections_from_yamnet,
    parse_args,
    parse_miss_command,
)


YAMNET_TIME = "2026-08-04T00:00:00.000Z"
SHADOW_TIME = "2026-08-04T00:00:03.000Z"


def detection(source: str, event_type: str, detected_at: str) -> Detection:
    return Detection(
        source=source,
        event_type=event_type,
        detected_at=detected_at,
        confidence=0.8,
        class_name=event_type.title(),
    )


class AudioShadowLiveReviewTests(unittest.TestCase):
    def test_extracts_yamnet_laughter_and_clap_decisions(self) -> None:
        detections = detections_from_yamnet(
            {
                "observedAt": YAMNET_TIME,
                "wouldTrigger": True,
                "selectedScore": 0.7,
                "selectedClass": "Laughter",
                "clapWouldTrigger": True,
                "clapScore": 0.9,
                "clapClass": "Clapping",
            }
        )

        self.assertEqual(
            [row.event_type for row in detections],
            ["LAUGHTER", "CLAP"],
        )
        self.assertTrue(all(row.source == "YAMNet" for row in detections))

    def test_extracts_only_efficientat_virtual_events(self) -> None:
        prediction = detections_from_shadow(
            {
                "recordType": "prediction",
                "observedAt": SHADOW_TIME,
                "events": {"laughter": {"wouldTrigger": True}},
            }
        )
        virtual = detections_from_shadow(
            {
                "recordType": "virtual-event",
                "eventType": "LAUGHTER",
                "detectedAt": SHADOW_TIME,
                "confidence": 0.8,
                "className": "Laughter",
                "virtualEventId": "shadow-event-1",
            }
        )

        self.assertEqual(prediction, [])
        self.assertEqual(len(virtual), 1)
        self.assertEqual(virtual[0].source, "EfficientAT MN10")

    def test_follower_skips_existing_rows_and_reads_new_complete_rows(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "yamnet.jsonl"
            existing = {
                "observedAt": YAMNET_TIME,
                "wouldTrigger": True,
                "selectedScore": 0.7,
                "selectedClass": "Laughter",
            }
            path.write_text(json.dumps(existing) + "\n", encoding="utf-8")
            follower = JsonlFollower(
                path,
                detections_from_yamnet,
                start_at_end=True,
            )

            self.assertEqual(follower.poll(), [])
            appended = {
                "observedAt": "2026-08-04T00:00:10.000Z",
                "clapWouldTrigger": True,
                "clapScore": 0.9,
                "clapClass": "Clapping",
            }
            with path.open("a", encoding="utf-8") as output:
                output.write(json.dumps(appended))
                output.flush()
            self.assertEqual(follower.poll(), [])
            with path.open("a", encoding="utf-8") as output:
                output.write("\n")

            detected = follower.poll()
            self.assertEqual(len(detected), 1)
            self.assertEqual(detected[0].event_type, "CLAP")

    def test_correlates_same_event_type_inside_tolerance(self) -> None:
        correlation = CorrelationBuffer(tolerance_seconds=12.0)
        yamnet = detection("YAMNet", "LAUGHTER", YAMNET_TIME)
        shadow = detection("EfficientAT MN10", "LAUGHTER", SHADOW_TIME)

        first = correlation.add(yamnet, now=100.0)
        second = correlation.add(shadow, now=103.0)

        self.assertIs(first, second)
        self.assertEqual(first.detected_sources, set(("YAMNet", "EfficientAT MN10")))
        self.assertEqual(correlation.ready(111.9), [])
        self.assertEqual(correlation.ready(112.0), [first])

    def test_does_not_correlate_other_type_or_outside_tolerance(self) -> None:
        correlation = CorrelationBuffer(tolerance_seconds=12.0)
        correlation.add(
            detection("YAMNet", "LAUGHTER", YAMNET_TIME),
            now=100.0,
        )
        correlation.add(
            detection("EfficientAT MN10", "CLAP", SHADOW_TIME),
            now=101.0,
        )
        correlation.add(
            detection(
                "EfficientAT MN10",
                "LAUGHTER",
                "2026-08-04T00:00:13.000Z",
            ),
            now=102.0,
        )

        self.assertEqual(len(correlation.candidates), 3)

    def test_yes_and_no_reviews_assign_model_outcomes(self) -> None:
        candidate = ReviewCandidate(
            event_type="LAUGHTER",
            first_arrived_monotonic=100.0,
            detections=[detection("YAMNet", "LAUGHTER", YAMNET_TIME)],
        )

        yes = build_review_record(candidate, "YES")
        no = build_review_record(candidate, "NO")

        self.assertEqual(
            yes["modelOutcomes"],
            {"YAMNet": "TP", "EfficientAT MN10": "FN"},
        )
        self.assertEqual(
            no["modelOutcomes"],
            {"YAMNet": "FP", "EfficientAT MN10": "TN"},
        )

    def test_manual_miss_records_false_negative_for_both_models(self) -> None:
        record = build_manual_miss_record("CLAP")

        self.assertEqual(record["recordType"], "manual-miss")
        self.assertEqual(record["agreement"], "neither-manual-miss")
        self.assertEqual(
            record["modelOutcomes"],
            {"YAMNet": "FN", "EfficientAT MN10": "FN"},
        )

    def test_miss_commands_are_explicit(self) -> None:
        self.assertEqual(parse_miss_command("MISS LAUGHTER"), ["LAUGHTER"])
        self.assertEqual(parse_miss_command("miss clap"), ["CLAP"])
        self.assertEqual(
            parse_miss_command("MISS BOTH"),
            ["LAUGHTER", "CLAP"],
        )
        self.assertIsNone(parse_miss_command("YES"))

    def test_cli_is_unbounded_and_has_no_side_effect_arguments(self) -> None:
        args = parse_args(
            [
                "--yamnet-diagnostics",
                "yamnet.jsonl",
                "--shadow-diagnostics",
                "shadow.jsonl",
            ]
        )

        self.assertFalse(hasattr(args, "duration"))
        self.assertFalse(hasattr(args, "event_dir"))
        self.assertFalse(hasattr(args, "mqtt_host"))
        self.assertFalse(hasattr(args, "api_base_url"))
        self.assertEqual(args.match_tolerance_seconds, 12.0)

    def test_durable_writer_flushes_each_manual_label(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "review.jsonl"
            writer = DurableJsonlWriter(path)
            writer.write({"recordType": "manual-review", "answer": "YES"})

            stored = path.read_text(encoding="utf-8")
            self.assertIn('"answer":"YES"', stored)
            writer.close()


if __name__ == "__main__":
    unittest.main()
