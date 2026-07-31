from pathlib import Path
import tempfile
import unittest

from vision_benchmark_runner import (
    FrameMeasurement,
    build_progress_payload,
    infer_runtime,
    percentile,
    run_sample,
    summarize_measurements,
)


class VisionBenchmarkTests(unittest.TestCase):
    def test_infers_explicit_local_runtime(self):
        self.assertEqual(infer_runtime(Path("yolo11n.pt")), "pytorch")
        self.assertEqual(infer_runtime(Path("yolo11n.engine")), "tensorrt")
        self.assertEqual(infer_runtime(Path("yolo11n.onnx")), "onnx")

    def test_interpolates_percentile(self):
        self.assertEqual(percentile([10.0, 20.0], 0.95), 19.5)
        self.assertIsNone(percentile([], 0.95))

    def test_summary_never_claims_accuracy_without_box_labels(self):
        measurements = [
            FrameMeasurement(
                sample_id="sample-001",
                repeat=1,
                frame_index=30,
                wall_ms=40.0,
                preprocess_ms=2.0,
                inference_ms=30.0,
                postprocess_ms=3.0,
                detection_count=2,
                class_counts={"person": 2},
            ),
            FrameMeasurement(
                sample_id="sample-001",
                repeat=1,
                frame_index=31,
                wall_ms=50.0,
                preprocess_ms=2.0,
                inference_ms=35.0,
                postprocess_ms=3.0,
                detection_count=1,
                class_counts={"person": 1},
            ),
        ]
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / "yolo11n.engine"
            model.write_bytes(b"engine")
            summary = summarize_measurements(
                measurements,
                run_id="vision-test",
                model_name="YOLO11n",
                runtime="tensorrt",
                model_path=model,
                dataset_name="office-mix-v1",
                warmup_frames=30,
                repeats=1,
                imgsz=640,
                device="0",
                confidence=0.25,
                iou=0.7,
                class_ids=[0],
            )

        self.assertEqual(summary["metrics"]["measuredFrames"], 2)
        self.assertEqual(summary["metrics"]["fps"], 22.222)
        self.assertEqual(summary["metrics"]["inferenceMeanMs"], 32.5)
        self.assertEqual(summary["metrics"]["classCounts"], {"person": 3})
        self.assertEqual(summary["accuracy"]["status"], "not-computed")
        self.assertEqual(summary["configuration"]["confidence"], 0.25)
        self.assertEqual(summary["configuration"]["iou"], 0.7)
        self.assertEqual(summary["configuration"]["classIds"], [0])

    def test_run_sample_forwards_explicit_detection_filters(self):
        class FakeModel:
            def __init__(self):
                self.options = None

            def predict(self, **options):
                self.options = options
                return []

        model = FakeModel()
        rows = run_sample(
            model,
            sample_id="sample-001",
            media_path=Path("scene.mp4"),
            repeat=1,
            device="0",
            imgsz=640,
            warmup_frames=30,
            max_frames=300,
            confidence=0.25,
            iou=0.7,
            class_ids=[0],
        )

        self.assertEqual(rows, [])
        self.assertEqual(model.options["conf"], 0.25)
        self.assertEqual(model.options["iou"], 0.7)
        self.assertEqual(model.options["classes"], [0])

    def test_progress_uses_measured_frames_and_completes_at_100_percent(self):
        running = build_progress_payload(
            run_id="vision-test",
            status="running",
            model_name="YOLO11n",
            runtime="tensorrt",
            dataset_name="office-mix-v1",
            completed_frames=50,
            total_frames=200,
            completed_tasks=1,
            total_tasks=4,
            repeat=1,
            sample_id="office-one",
        )
        completed = build_progress_payload(
            run_id="vision-test",
            status="completed",
            model_name="YOLO11n",
            runtime="tensorrt",
            dataset_name="office-mix-v1",
            completed_frames=180,
            total_frames=200,
            completed_tasks=4,
            total_tasks=4,
        )

        self.assertEqual(running["progress"]["percent"], 25.0)
        self.assertEqual(running["current"]["sampleId"], "office-one")
        self.assertEqual(completed["progress"]["percent"], 100.0)


if __name__ == "__main__":
    unittest.main()
