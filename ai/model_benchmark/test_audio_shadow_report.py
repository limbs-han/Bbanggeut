import unittest

from audio_shadow_report import compare, match_events, yamnet_events


class AudioShadowReportTests(unittest.TestCase):
    def test_yamnet_rows_become_operational_events(self) -> None:
        events = yamnet_events(
            [
                {
                    "observedAt": "2026-08-04T00:00:00.000Z",
                    "wouldTrigger": True,
                    "selectedScore": 0.8,
                    "selectedClass": "Laughter",
                    "clapWouldTrigger": True,
                    "clapScore": 0.9,
                    "clapClass": "Clapping",
                }
            ]
        )
        self.assertEqual(
            [event["eventType"] for event in events],
            ["LAUGHTER", "CLAP"],
        )

    def test_matching_is_event_type_specific_and_within_tolerance(self) -> None:
        operational = [
            {
                "eventType": "LAUGHTER",
                "detectedAt": "2026-08-04T00:00:00.000Z",
            }
        ]
        shadow = [
            {
                "eventType": "CLAP",
                "detectedAt": "2026-08-04T00:00:01.000Z",
            },
            {
                "eventType": "LAUGHTER",
                "detectedAt": "2026-08-04T00:00:05.000Z",
            },
        ]
        matches, yamnet_only, shadow_only = match_events(
            operational,
            shadow,
            tolerance_seconds=12.0,
        )
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0]["absoluteGapSeconds"], 5.0)
        self.assertEqual(yamnet_only, [])
        self.assertEqual(len(shadow_only), 1)
        self.assertEqual(shadow_only[0]["eventType"], "CLAP")

    def test_disagreements_are_unreviewed_not_fp_or_fn(self) -> None:
        yamnet_rows = [
            {
                "observedAt": "2026-08-04T00:00:00.000Z",
                "inferenceMs": 5.0,
                "wouldTrigger": True,
                "selectedScore": 0.8,
                "selectedClass": "Laughter",
            },
            {
                "observedAt": "2026-08-04T00:01:00.000Z",
                "inferenceMs": 6.0,
            },
        ]
        shadow_rows = [
            {
                "recordType": "startup",
                "observedAt": "2026-08-04T00:00:00.000Z",
                "mode": "shadow-only",
            },
            {
                "recordType": "prediction",
                "observedAt": "2026-08-04T00:01:00.000Z",
                "inferenceMs": 40.0,
            },
        ]
        summary, review = compare(yamnet_rows, shadow_rows, 12.0)
        self.assertEqual(
            summary["status"],
            "shadow-comparison-needs-manual-review",
        )
        self.assertEqual(summary["events"]["laughter"]["yamnetOnlyCount"], 1)
        self.assertEqual(len(review), 1)
        self.assertEqual(review[0]["reviewStatus"], "unreviewed")
        self.assertIsNone(review[0]["groundTruth"])


if __name__ == "__main__":
    unittest.main()
