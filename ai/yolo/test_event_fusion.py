"""Tests for recall-first fusion of laughter and vision events."""

from __future__ import annotations

import unittest

from event_fusion_service import build_fused_event, validate_laughter_event


class EventFusionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.laughter = {
            "schema_version": "1.0",
            "event_id": "0a61d047-63ea-4ae0-917e-3787a572ec02",
            "device_id": "homecam-001",
            "event_type": "laughter",
            "detected_at": "2026-07-23T03:30:00.000Z",
            "score": 0.75,
            "clip": {"pre_seconds": 60, "post_seconds": 60},
        }
        self.vision = {
            "target_ids": [1, 3],
            "track_ids": [1, 3, 8],
            "target_count": 2,
            "total_stable_objects": 3,
            "state": "TRACKING",
            "direction": "RIGHT",
            "error_x": 0.2,
            "error_y": -0.03,
            "limited_group": True,
            "object_counts": {"person": 2, "cat": 0, "dog": 1},
        }

    def test_recent_vision_context_is_attached(self) -> None:
        fused = build_fused_event(self.laughter, self.vision, 120, 2_000)

        context = fused["vision_context"]
        self.assertTrue(context["available"])
        self.assertEqual(context["person_count"], 2)
        self.assertEqual(context["dog_count"], 1)
        self.assertEqual(context["object_count"], 3)
        self.assertEqual(context["track_ids"], [1, 3, 8])
        self.assertEqual(context["target_ids"], [1, 3])
        self.assertEqual(
            fused["event_id"],
            "0a61d047-63ea-4ae0-917e-3787a572ec02",
        )
        validate_laughter_event(fused)

    def test_stale_vision_does_not_block_laughter_event(self) -> None:
        fused = build_fused_event(self.laughter, self.vision, 2_001, 2_000)

        self.assertEqual(fused["event_type"], "laughter")
        self.assertEqual(
            fused["event_id"],
            "0a61d047-63ea-4ae0-917e-3787a572ec02",
        )
        self.assertFalse(fused["vision_context"]["available"])
        self.assertEqual(fused["vision_context"]["age_ms"], 2_001)
        self.assertEqual(fused["vision_context"]["object_count"], 0)
        self.assertEqual(fused["vision_context"]["track_ids"], [])

    def test_missing_vision_does_not_block_laughter_event(self) -> None:
        fused = build_fused_event(self.laughter, None, None, 2_000)

        self.assertEqual(fused["event_type"], "laughter")
        self.assertFalse(fused["vision_context"]["available"])
        invalid = dict(self.laughter)
        invalid["event_id"] = "not-a-uuid"
        invalid["score"] = "high"
        with self.assertRaises(ValueError):
            validate_laughter_event(invalid)


if __name__ == "__main__":
    unittest.main()
