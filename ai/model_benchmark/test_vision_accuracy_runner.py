from pathlib import Path
import tempfile
import unittest

from vision_accuracy_runner import (
    DetectionBox,
    MatchCounts,
    box_iou,
    build_progress,
    dataset_fingerprint,
    discover_image_label_pairs,
    load_yolo_labels,
    match_boxes,
    metrics_from_counts,
    scenario_from_stem,
    summarize_resources,
)


class VisionAccuracyTests(unittest.TestCase):
    def test_converts_yolo_labels_to_corner_coordinates(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frame.txt"
            path.write_text("0 0.5 0.5 0.4 0.2\n", encoding="utf-8")

            boxes = load_yolo_labels(path)

        self.assertEqual(len(boxes), 1)
        self.assertAlmostEqual(boxes[0].x1, 0.3)
        self.assertAlmostEqual(boxes[0].y1, 0.4)
        self.assertAlmostEqual(boxes[0].x2, 0.7)
        self.assertAlmostEqual(boxes[0].y2, 0.6)

    def test_rejects_invalid_yolo_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frame.txt"
            path.write_text("0 0.5 0.5 1.2 0.2\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                load_yolo_labels(path)

    def test_matches_each_ground_truth_box_at_most_once(self):
        expected = [DetectionBox(0, 0.1, 0.1, 0.5, 0.5)]
        predictions = [
            DetectionBox(0, 0.1, 0.1, 0.5, 0.5, 0.9),
            DetectionBox(0, 0.1, 0.1, 0.5, 0.5, 0.8),
        ]

        counts = match_boxes(expected, predictions, iou_threshold=0.5)

        self.assertEqual(counts.true_positive, 1)
        self.assertEqual(counts.false_positive, 1)
        self.assertEqual(counts.false_negative, 0)

    def test_does_not_match_different_classes(self):
        expected = [DetectionBox(0, 0.1, 0.1, 0.5, 0.5)]
        predictions = [DetectionBox(1, 0.1, 0.1, 0.5, 0.5, 0.9)]

        counts = match_boxes(expected, predictions, iou_threshold=0.5)

        self.assertEqual(counts, MatchCounts(0, 1, 1))

    def test_computes_iou_and_operating_metrics(self):
        first = DetectionBox(0, 0.0, 0.0, 0.5, 0.5)
        second = DetectionBox(0, 0.25, 0.25, 0.75, 0.75)
        self.assertAlmostEqual(box_iou(first, second), 1 / 7)

        metrics = metrics_from_counts(MatchCounts(8, 2, 2))
        self.assertEqual(metrics["precision"], 0.8)
        self.assertEqual(metrics["recall"], 0.8)
        self.assertEqual(metrics["f1"], 0.8)

    def test_normalizes_uploaded_duplicate_scenario_name(self):
        self.assertEqual(
            scenario_from_stem("f52fc7e5-office-empty-001__000002"),
            "office-empty-001",
        )
        self.assertEqual(
            scenario_from_stem("office-three-group-001__000040"),
            "office-three-group-001",
        )

    def test_requires_one_label_per_image(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "images" / "test").mkdir(parents=True)
            (root / "labels" / "test").mkdir(parents=True)
            (root / "images" / "test" / "frame.jpg").write_bytes(b"image")

            with self.assertRaises(ValueError):
                discover_image_label_pairs(root)

    def test_fingerprint_reports_duplicate_image_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image_root = root / "images" / "test"
            label_root = root / "labels" / "test"
            image_root.mkdir(parents=True)
            label_root.mkdir(parents=True)
            pairs = []
            for stem in ("first", "second"):
                image = image_root / f"{stem}.jpg"
                label = label_root / f"{stem}.txt"
                image.write_bytes(b"same-image")
                label.write_text("", encoding="utf-8")
                pairs.append((image, label))

            fingerprint, duplicates = dataset_fingerprint(root, pairs)

        self.assertEqual(len(fingerprint), 64)
        self.assertEqual(duplicates, 1)

    def test_summarizes_jetson_resource_peaks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "resources.log"
            path.write_text(
                "RAM 3000/7620MB GR3D_FREQ 40% gpu@48.0C VDD_IN 5000mW\n"
                "RAM 3200/7620MB GR3D_FREQ 80% gpu@52.0C VDD_IN 7000mW\n",
                encoding="utf-8",
            )

            summary = summarize_resources(path)

        self.assertEqual(summary["status"], "computed")
        self.assertEqual(summary["sampleCount"], 2)
        self.assertEqual(summary["gpuPercentMax"], 80.0)
        self.assertEqual(summary["ramUsedMbMax"], 3200.0)
        self.assertEqual(summary["temperatureCMax"], 52.0)
        self.assertEqual(summary["powerMwMax"], 7000.0)

    def test_progress_identifies_repeated_comparison_trial(self):
        progress = build_progress(
            run_id="vision-test",
            model_name="YOLO11n",
            dataset_name="office-test",
            status="running",
            stage="predicting",
            completed=20,
            total=100,
            trial_index=2,
            trial_count=3,
            execution_order=5,
            comparison_id="comparison-test",
            current_image="frame.jpg",
        )

        self.assertEqual(progress["comparison"]["id"], "comparison-test")
        self.assertEqual(progress["comparison"]["trialIndex"], 2)
        self.assertEqual(progress["comparison"]["trialCount"], 3)
        self.assertEqual(progress["comparison"]["executionOrder"], 5)
        self.assertEqual(progress["current"]["repeat"], 2)


if __name__ == "__main__":
    unittest.main()
