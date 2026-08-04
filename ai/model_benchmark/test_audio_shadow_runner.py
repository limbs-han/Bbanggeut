import json
import math
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

from audio_shadow_runner import (
    JsonlWriter,
    SlidingAudioBuffer,
    VirtualEventGate,
    event_score,
    parse_args,
    run,
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

    def test_shadow_run_records_predictions_without_operational_authority(self) -> None:
        class FakeArray(list):
            @property
            def size(self) -> int:
                return len(self)

            def reshape(self, shape: int):
                self.requested_shape = shape
                return self

        fake_numpy = types.ModuleType("numpy")
        fake_numpy.float32 = float
        fake_numpy.asarray = lambda values, dtype=None: FakeArray(values)

        def frombuffer(values, dtype=None):
            from array import array

            del dtype
            decoded = array("f")
            decoded.frombytes(values)
            return FakeArray(decoded)

        fake_numpy.frombuffer = frombuffer
        fake_numpy.isfinite = lambda values: [
            math.isfinite(value) for value in values
        ]
        fake_numpy.all = all
        fake_numpy.argmax = lambda values: max(
            range(len(values)),
            key=lambda index: values[index],
        )
        fake_numpy.square = lambda values: [value * value for value in values]
        fake_numpy.mean = lambda values: sum(values) / len(values)
        fake_numpy.sqrt = math.sqrt

        class FakePredictor:
            class_names = [
                "Speech",
                "Laughter",
                "Baby laughter",
                "Giggle",
                "Snicker",
                "Belly laugh",
                "Chuckle, chortle",
                "Clapping",
                "Applause",
            ]
            precision = "fp16"

            def __init__(self, *args, **kwargs) -> None:
                del args, kwargs

            def predict(self, waveform):
                self.waveform = waveform
                return FakeArray(
                    [0.1, 0.9, 0.2, 0.2, 0.2, 0.2, 0.2, 0.8, 0.3]
                ), 4.2

        class FakeAudioStream:
            def __init__(self, command, *, on_block, **kwargs) -> None:
                del command, kwargs
                self.on_block = on_block

            def start(self) -> None:
                from array import array

                self.on_block(array("f", [1.0] * 320).tobytes())

            def close(self) -> None:
                pass

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model = root / "efficientat.pt"
            model.write_bytes(b"shadow-model")
            source = root / "source"
            class_map = source / "metadata" / "class_labels_indices.csv"
            class_map.parent.mkdir(parents=True)
            class_map.write_text("index,mid,display_name\n", encoding="utf-8")
            diagnostics = root / "efficientat_shadow.jsonl"
            args = parse_args(
                [
                    "--stream-url",
                    "rtsp://127.0.0.1/homecam/ai",
                    "--model",
                    str(model),
                    "--source-repo",
                    str(source),
                    "--class-map",
                    str(class_map),
                    "--diagnostics-jsonl",
                    str(diagnostics),
                    "--context-seconds",
                    "0.01",
                    "--hop-seconds",
                    "0.01",
                    "--block-seconds",
                    "0.01",
                    "--laughter-threshold",
                    "0.5",
                    "--clap-threshold",
                    "0.5",
                    "--cooldown-seconds",
                    "0",
                    "--max-windows",
                    "1",
                ]
            )

            with (
                patch.dict(sys.modules, {"numpy": fake_numpy}),
                patch(
                    "audio_shadow_runner.EfficientAtPredictor",
                    FakePredictor,
                ),
                patch(
                    "audio_shadow_runner.ReconnectingFfmpegAudio",
                    FakeAudioStream,
                ),
                patch(
                    "audio_shadow_runner.detect_rtsp_timeout_option",
                    return_value="stimeout",
                ),
                patch(
                    "audio_shadow_runner.build_audio_command",
                    return_value=["fake-ffmpeg"],
                ),
            ):
                self.assertEqual(run(args), 0)

            records = [
                json.loads(line)
                for line in diagnostics.read_text(encoding="utf-8").splitlines()
            ]
            startup = next(
                row for row in records if row["recordType"] == "startup"
            )
            self.assertFalse(startup["operationalAuthority"])
            self.assertEqual(
                startup["sideEffects"],
                {
                    "trigger": False,
                    "mqtt": False,
                    "upload": False,
                    "api": False,
                },
            )
            predictions = [
                row for row in records if row["recordType"] == "prediction"
            ]
            self.assertEqual(len(predictions), 1)
            self.assertTrue(
                predictions[0]["events"]["laughter"]["wouldTrigger"]
            )
            virtual_events = [
                row for row in records if row["recordType"] == "virtual-event"
            ]
            self.assertEqual(
                {row["eventType"] for row in virtual_events},
                {"LAUGHTER", "CLAP"},
            )
            self.assertTrue(
                all(
                    row["operationalAuthority"] is False
                    and row["virtualEventId"].startswith("shadow-")
                    for row in virtual_events
                )
            )
            self.assertEqual(
                sorted(path.name for path in root.glob("*.json*")),
                ["efficientat_shadow.jsonl"],
            )


if __name__ == "__main__":
    unittest.main()
