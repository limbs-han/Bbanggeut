from pathlib import Path
import tempfile
import unittest

from audio_shadow_runner import (
    JsonlWriter,
    SlidingAudioBuffer,
    VirtualEventGate,
    event_score,
    parse_args,
)


class AudioShadowRunnerTests(unittest.TestCase):
    def test_sliding_buffer_waits_for_context_then_hop(self) -> None:
        buffer = SlidingAudioBuffer(window_samples=4, hop_samples=2)
        import threading

        stop = threading.Event()
        buffer.append([1.0, 2.0, 3.0])
        self.assertIsNone(buffer.wait_for_window(stop, timeout_seconds=0.0))
        buffer.append([4.0])
        self.assertEqual(
            list(buffer.wait_for_window(stop, timeout_seconds=0.0)),
            [1.0, 2.0, 3.0, 4.0],
        )
        buffer.append([5.0])
        self.assertIsNone(buffer.wait_for_window(stop, timeout_seconds=0.0))
        buffer.append([6.0])
        self.assertEqual(
            list(buffer.wait_for_window(stop, timeout_seconds=0.0)),
            [3.0, 4.0, 5.0, 6.0],
        )

    def test_stream_reset_requires_a_fresh_full_context(self) -> None:
        import threading

        buffer = SlidingAudioBuffer(window_samples=4, hop_samples=2)
        stop = threading.Event()
        buffer.append([1.0] * 4)
        self.assertIsNotNone(buffer.wait_for_window(stop, timeout_seconds=0.0))
        buffer.reset()
        buffer.append([1.0] * 3)
        self.assertIsNone(buffer.wait_for_window(stop, timeout_seconds=0.0))

    def test_gate_matches_consecutive_and_cooldown_policy(self) -> None:
        gate = VirtualEventGate(
            threshold=0.5,
            required_windows=2,
            cooldown_seconds=12.0,
        )
        self.assertFalse(gate.observe(0.6, 0.0).triggered)
        self.assertTrue(gate.observe(0.7, 2.5).triggered)
        suppressed = gate.observe(0.8, 5.0)
        self.assertFalse(suppressed.triggered)
        self.assertGreater(suppressed.cooldown_remaining_seconds, 0.0)
        self.assertTrue(gate.observe(0.9, 15.0).triggered)

    def test_negative_window_resets_consecutive_state(self) -> None:
        gate = VirtualEventGate(0.5, 2, 0.0)
        gate.observe(0.8, 0.0)
        self.assertFalse(gate.observe(0.2, 1.0).triggered)
        self.assertFalse(gate.observe(0.8, 2.0).triggered)
        self.assertTrue(gate.observe(0.8, 3.0).triggered)

    def test_event_score_uses_highest_mapped_class(self) -> None:
        score, class_name = event_score(
            [0.1, 0.7, 0.4],
            (1, 2),
            ["Speech", "Laughter", "Giggle"],
        )
        self.assertAlmostEqual(score, 0.7, places=6)
        self.assertEqual(class_name, "Laughter")

    def test_cli_has_no_operational_side_effect_arguments(self) -> None:
        args = parse_args(
            [
                "--stream-url",
                "rtsp://127.0.0.1/example",
                "--model",
                "model.pt",
                "--source-repo",
                "source",
                "--diagnostics-jsonl",
                "shadow.jsonl",
            ]
        )
        self.assertFalse(hasattr(args, "event_dir"))
        self.assertFalse(hasattr(args, "mqtt_host"))
        self.assertFalse(hasattr(args, "api_base_url"))

    def test_jsonl_writer_flushes_each_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "shadow.jsonl"
            writer = JsonlWriter(path)
            writer.write({"recordType": "prediction", "score": 0.5})
            self.assertIn('"recordType":"prediction"', path.read_text())
            writer.close()


if __name__ == "__main__":
    unittest.main()
