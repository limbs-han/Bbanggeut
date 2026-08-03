"""Tests for clap and user-defined wake-name decisions."""

from __future__ import annotations

import unittest

from audio_event_detection import (
    CLAP_CLASS_KEYWORDS,
    ConsecutiveClapDetector,
    WakeNameDetector,
    count_impulsive_onsets,
    find_class_indices,
    normalize_wake_phrase,
    wake_phrase_similarity,
)


class AudioEventDetectionTests(unittest.TestCase):
    def test_counts_separated_impulsive_onsets(self) -> None:
        sample_rate = 1_000
        samples = [0.0] * sample_rate
        for start in (200, 600):
            samples[start : start + 20] = [0.8] * 20

        self.assertEqual(
            count_impulsive_onsets(samples, sample_rate),
            2,
        )

    def test_single_impulse_is_not_a_consecutive_clap(self) -> None:
        sample_rate = 1_000
        samples = [0.0] * sample_rate
        samples[200:220] = [0.8] * 20

        self.assertEqual(
            count_impulsive_onsets(samples, sample_rate),
            1,
        )

    def test_finds_only_clap_related_yamnet_classes(self) -> None:
        names = ["Speech", "Clapping", "Applause", "Laughter"]

        self.assertEqual(
            find_class_indices(names, CLAP_CLASS_KEYWORDS),
            [1, 2],
        )

    def test_single_clap_window_does_not_trigger(self) -> None:
        detector = ConsecutiveClapDetector(
            threshold=0.3,
            required_windows=3,
            minimum_active_seconds=0.8,
            maximum_gap_seconds=0.7,
            cooldown_seconds=10,
        )

        self.assertIsNone(detector.observe(0.8, 1.0, 1))
        self.assertIsNone(detector.observe(0.1, 1.5, 1))
        self.assertEqual(detector.positive_windows, 0)

    def test_consecutive_clap_windows_trigger_once(self) -> None:
        detector = ConsecutiveClapDetector(
            threshold=0.3,
            required_windows=3,
            minimum_active_seconds=0.8,
            maximum_gap_seconds=0.7,
            cooldown_seconds=10,
        )

        self.assertIsNone(detector.observe(0.7, 1.0, 2))
        self.assertIsNone(detector.observe(0.8, 1.5, 2))
        detection = detector.observe(0.9, 2.0, 2)

        self.assertIsNotNone(detection)
        assert detection is not None
        self.assertEqual(detection.positive_windows, 3)
        self.assertEqual(detection.onset_count, 2)
        self.assertAlmostEqual(detection.active_seconds, 1.0)
        self.assertIsNone(detector.observe(0.9, 2.5, 2))
        self.assertIsNone(detector.observe(0.9, 3.0, 2))
        self.assertIsNone(detector.observe(0.9, 3.5, 2))

    def test_three_onset_policy_rejects_two_and_accepts_three(self) -> None:
        detector = ConsecutiveClapDetector(
            threshold=0.3,
            required_windows=2,
            minimum_active_seconds=0.4,
            maximum_gap_seconds=0.75,
            cooldown_seconds=12,
            required_onsets=3,
        )

        self.assertIsNone(detector.observe(0.9, 1.0, 2))
        self.assertIsNone(detector.observe(0.9, 1.5, 3))
        detection = detector.observe(0.9, 2.0, 3)

        self.assertIsNotNone(detection)
        assert detection is not None
        self.assertEqual(detection.onset_count, 3)

    def test_clap_gap_restarts_sequence(self) -> None:
        detector = ConsecutiveClapDetector(
            threshold=0.3,
            required_windows=2,
            minimum_active_seconds=0.4,
            maximum_gap_seconds=0.7,
            cooldown_seconds=0,
        )

        self.assertIsNone(detector.observe(0.9, 1.0, 2))
        self.assertIsNone(detector.observe(0.9, 2.0, 2))
        self.assertIsNotNone(detector.observe(0.9, 2.5, 2))

    def test_wake_phrase_normalization_and_matching(self) -> None:
        self.assertEqual(normalize_wake_phrase(" 윌리엄-제임스! "), "윌리엄제임스")
        self.assertEqual(
            wake_phrase_similarity(
                "윌리엄 제임스",
                "저기 윌리엄 제임스, 이쪽을 봐",
            ),
            1.0,
        )
        self.assertGreaterEqual(
            wake_phrase_similarity("윌리엄 제임스", "윌리암 제임스"),
            0.82,
        )

    def test_wake_name_is_speaker_independent_and_rate_limited(self) -> None:
        detector = WakeNameDetector(
            phrase="윌리엄 제임스",
            threshold=0.82,
            cooldown_seconds=5,
        )

        first = detector.observe("윌리엄 제임스 여기 봐", 10.0)
        self.assertIsNotNone(first)
        self.assertIsNone(detector.observe("윌리엄 제임스", 12.0))
        self.assertIsNotNone(detector.observe("윌리엄 제임스", 16.0))
        self.assertIsNone(detector.observe("오늘 날씨가 좋다", 22.0))


if __name__ == "__main__":
    unittest.main()
