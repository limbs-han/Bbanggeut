"""Tests for YAMNet laughter score aggregation."""

from __future__ import annotations

import unittest

from laughter_scoring import percentile, summarize_laughter_scores


class LaughterScoringTests(unittest.TestCase):
    def test_percentile_interpolates(self) -> None:
        self.assertAlmostEqual(percentile([0.0, 1.0], 0.90), 0.9)
        self.assertAlmostEqual(percentile([0.4], 0.90), 0.4)

    def test_aggregation_can_choose_different_classes(self) -> None:
        rows = [
            [0.9, 0.5],
            [0.0, 0.5],
        ]

        maximum = summarize_laughter_scores(rows, ["spike", "steady"], "max")
        average = summarize_laughter_scores(rows, ["spike", "steady"], "mean")

        self.assertEqual(maximum.selected_class, "spike")
        self.assertAlmostEqual(maximum.selected_score, 0.9)
        self.assertEqual(average.selected_class, "steady")
        self.assertAlmostEqual(average.selected_score, 0.5)
        self.assertAlmostEqual(average.p90_score, 0.81)

    def test_rejects_malformed_input(self) -> None:
        with self.assertRaises(ValueError):
            summarize_laughter_scores([], ["laughter"], "mean")
        with self.assertRaises(ValueError):
            summarize_laughter_scores([[0.1, 0.2]], ["laughter"], "mean")
        with self.assertRaises(ValueError):
            summarize_laughter_scores([[0.1]], ["laughter"], "median")


if __name__ == "__main__":
    unittest.main()
