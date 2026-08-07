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
    validate_args,
)


class FakeArray(list):
    @property
    def size(self) -> int:
        return len(self)

    def reshape(self, shape: int):
        self.requested_shape = shape
        return self


def build_fake_numpy() -> types.ModuleType:
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
    return fake_numpy


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
        return FakeArray([0.1, 0.9, 0.2, 0.2, 0.2, 0.2, 0.2, 0.8, 0.3]), 4.2


class FakeAudioStream:
    def __init__(self, command, *, on_block, **kwargs) -> None:
        del command, kwargs
        self.on_block = on_block

    def start(self) -> None:
        from array import array

        self.on_block(array("f", [1.0] * 320).tobytes())

    def close(self) -> None:
        pass


def run_with_fakes(root: Path, extra_argv: list[str]) -> list[dict]:
    """Run one window against fake audio and return the diagnostics records."""

    model = root / "efficientat.pt"
    model.write_bytes(b"shadow-model")
    source = root / "source"
    class_map = source / "metadata" / "class_labels_indices.csv"
    class_map.parent.mkdir(parents=True, exist_ok=True)
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
            # These tests drive a single window to check the event plumbing,
            # not the clap gate. The shipped default is 2, which by design
            # cannot fire on one window.
            "--clap-consecutive",
            "1",
            "--cooldown-seconds",
            "0",
            "--max-windows",
            "1",
            *extra_argv,
        ]
    )

    with (
        patch.dict(sys.modules, {"numpy": build_fake_numpy()}),
        patch("audio_shadow_runner.EfficientAtPredictor", FakePredictor),
        patch("audio_shadow_runner.ReconnectingFfmpegAudio", FakeAudioStream),
        patch(
            "audio_shadow_runner.detect_rtsp_timeout_option",
            return_value="stimeout",
        ),
        patch(
            "audio_shadow_runner.build_audio_command",
            return_value=["fake-ffmpeg"],
        ),
    ):
        if run(args) != 0:
            raise AssertionError("runner did not exit cleanly")

    return [
        json.loads(line)
        for line in diagnostics.read_text(encoding="utf-8").splitlines()
    ]


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

    @staticmethod
    def _base_argv() -> list[str]:
        return [
            "--stream-url",
            "rtsp://127.0.0.1/example",
            "--model",
            "model.pt",
            "--source-repo",
            "source",
            "--diagnostics-jsonl",
            "shadow.jsonl",
        ]

    def test_shadow_mode_has_no_operational_side_effects(self) -> None:
        args = parse_args(self._base_argv())

        self.assertFalse(args.operational)
        self.assertIsNone(args.event_dir)
        self.assertIsNone(args.mqtt_host)
        self.assertFalse(hasattr(args, "api_base_url"))

    def test_clap_defaults_to_two_consecutive_windows(self) -> None:
        # A door slam and sustained applause score alike in one window; only
        # persistence separates them. Laughter has no such twin, so it stays
        # at 1. Dropping clap to 1 would trade the distinction for nothing.
        args = parse_args(self._base_argv())

        self.assertEqual(args.clap_consecutive, 2)
        self.assertEqual(args.laughter_consecutive, 1)

    def test_laughter_default_is_the_field_corrected_threshold(self) -> None:
        # The dev-set argmax 0.01691491 fired on ordinary conversation. This
        # runner can now hold event authority, so its default must not be the
        # value that over-fires.
        args = parse_args(self._base_argv())

        self.assertEqual(args.laughter_threshold, 0.03)

    def test_side_effect_arguments_require_operational(self) -> None:
        for extra in (
            ["--event-dir", "events"],
            ["--mqtt-host", "127.0.0.1"],
        ):
            with self.subTest(extra=extra[0]):
                args = parse_args(self._base_argv() + extra)
                with self.assertRaises(SystemExit) as raised:
                    validate_args(args)
                self.assertIn("--operational", str(raised.exception))

    def test_operational_requires_a_side_effect_destination(self) -> None:
        args = parse_args(self._base_argv() + ["--operational"])
        with self.assertRaises(SystemExit) as raised:
            validate_args(args)
        self.assertIn("--event-dir", str(raised.exception))

    def test_operational_mqtt_requires_a_device_id(self) -> None:
        args = parse_args(
            self._base_argv() + ["--operational", "--mqtt-host", "127.0.0.1"]
        )
        with self.assertRaises(SystemExit) as raised:
            validate_args(args)
        self.assertIn("--device-id", str(raised.exception))

    def test_jsonl_writer_flushes_each_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "shadow.jsonl"
            writer = JsonlWriter(path)
            writer.write({"recordType": "prediction", "score": 0.5})
            self.assertIn('"recordType":"prediction"', path.read_text())
            writer.close()

    def test_shadow_run_records_predictions_without_operational_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            records = run_with_fakes(root, [])

            startup = next(
                row for row in records if row["recordType"] == "startup"
            )
            self.assertFalse(startup["operationalAuthority"])
            self.assertEqual(startup["mode"], "shadow-only")
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

    def test_prediction_carries_the_dashboard_diagnostics_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            records = run_with_fakes(Path(temporary), [])

            prediction = next(
                row for row in records if row["recordType"] == "prediction"
            )
            # The servo dashboard and the stack readiness probe both key off
            # the YAMNet diagnostics shape.
            self.assertAlmostEqual(prediction["selectedScore"], 0.9, places=6)
            self.assertEqual(prediction["selectedClass"], "Laughter")
            self.assertEqual(prediction["threshold"], 0.5)
            self.assertTrue(prediction["wouldTrigger"])

    def test_operational_run_writes_triggers_for_the_uploader(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            event_dir = root / "events"
            records = run_with_fakes(
                root,
                [
                    "--operational",
                    "--event-dir",
                    str(event_dir),
                    "--clip-seconds",
                    "60",
                    "--enable-clap-events",
                ],
            )

            startup = next(
                row for row in records if row["recordType"] == "startup"
            )
            self.assertTrue(startup["operationalAuthority"])
            self.assertEqual(startup["mode"], "operational")
            self.assertTrue(startup["sideEffects"]["trigger"])
            self.assertFalse(startup["sideEffects"]["mqtt"])

            self.assertEqual(
                [row["recordType"] for row in records].count("virtual-event"),
                0,
            )
            events = [row for row in records if row["recordType"] == "event"]
            self.assertEqual(
                {row["eventType"] for row in events},
                {"LAUGHTER", "CLAP"},
            )
            self.assertTrue(
                all(row["operationalAuthority"] is True for row in events)
            )

            triggers = sorted(event_dir.glob("*.trigger.json"))
            self.assertEqual(len(triggers), 2)
            payloads = [
                json.loads(path.read_text(encoding="utf-8"))
                for path in triggers
            ]
            self.assertEqual(
                {payload["type"] for payload in payloads},
                {"LAUGHTER", "CLAP"},
            )
            laughter = next(
                payload
                for payload in payloads
                if payload["type"] == "LAUGHTER"
            )
            self.assertEqual(laughter["className"], "Laughter")
            self.assertAlmostEqual(laughter["confidence"], 0.9, places=6)
            self.assertEqual(laughter["preSeconds"], 60.0)
            self.assertEqual(
                laughter["metadata"]["model"],
                "efficientat-mn10",
            )
            self.assertEqual(
                {payload["eventId"] for payload in payloads},
                {row["eventId"] for row in events},
            )

    def test_operational_run_can_suppress_clap_events(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            event_dir = root / "events"
            records = run_with_fakes(
                root,
                ["--operational", "--event-dir", str(event_dir)],
            )

            events = [row for row in records if row["recordType"] == "event"]
            self.assertEqual(
                {row["eventType"] for row in events},
                {"LAUGHTER"},
            )
            triggers = sorted(event_dir.glob("*.trigger.json"))
            self.assertEqual(len(triggers), 1)
            payload = json.loads(triggers[0].read_text(encoding="utf-8"))
            self.assertEqual(payload["type"], "LAUGHTER")


if __name__ == "__main__":
    unittest.main()
