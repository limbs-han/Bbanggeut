"""Unit tests for MQTT validation and hardware-independent servo control."""

from __future__ import annotations

from datetime import datetime, timezone
import io
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

from servo_controller import (
    AxisConfig,
    Pca9685ServoOutput,
    ServoController,
    build_axis_configs,
    load_saved_position,
    parse_args,
    parse_framing_target,
    save_position_atomic,
)


DEVICE_ID = "11111111-1111-4111-8111-111111111111"


class RecordingOutput:
    def __init__(self) -> None:
        self.positions: list[tuple[float, float]] = []
        self.closed = False

    def write_positions(self, pan_deg: float, tilt_deg: float) -> None:
        self.positions.append((pan_deg, tilt_deg))

    def close(self) -> None:
        self.closed = True


class FakeSmbus:
    def __init__(self, bus_number: int, *, initial_mode1: int = 0) -> None:
        self.bus_number = bus_number
        self.initial_mode1 = initial_mode1
        self.byte_writes: list[tuple[int, int, int]] = []
        self.block_writes: list[tuple[int, int, list[int]]] = []
        self.closed = False

    def read_byte_data(self, address: int, register: int) -> int:
        del address
        if register == Pca9685ServoOutput.MODE1:
            return self.initial_mode1
        return 0

    def write_byte_data(self, address: int, register: int, value: int) -> None:
        self.byte_writes.append((address, register, value))

    def write_i2c_block_data(
        self,
        address: int,
        register: int,
        values: list[int],
    ) -> None:
        self.block_writes.append((address, register, values))

    def close(self) -> None:
        self.closed = True


def axis(
    name: str,
    *,
    channel: int,
    minimum: float,
    maximum: float,
    park: float = 0.0,
) -> AxisConfig:
    return AxisConfig(
        name=name,
        channel=channel,
        minimum_deg=minimum,
        home_deg=0.0,
        park_deg=park,
        maximum_deg=maximum,
        home_pulse_us=1500.0,
        pulse_us_per_degree=5.0,
        pulse_direction=1,
        response_gain_deg_per_second=40.0,
        max_speed_deg_per_second=20.0,
        minimum_pulse_us=1000.0,
        maximum_pulse_us=2000.0,
    )


def payload(
    *,
    state: str = "TRACKING",
    command_x: str = "RIGHT",
    command_y: str = "DOWN",
    error_x: float = 0.5,
    error_y: float = 0.25,
    sequence: int = 1,
    sent_at_epoch: float = 100.0,
) -> dict[str, object]:
    return {
        "schema_version": "1.1",
        "device_id": DEVICE_ID,
        "sent_at": datetime.fromtimestamp(
            sent_at_epoch, timezone.utc
        ).isoformat().replace("+00:00", "Z"),
        "sequence": sequence,
        "state": state,
        "direction": "RIGHT_DOWN",
        "command_x": command_x,
        "command_y": command_y,
        "error_x": error_x,
        "error_y": error_y,
        "target_ids": [1],
        "ttl_ms": 500,
    }


class FramingTargetValidationTests(unittest.TestCase):
    def test_parses_two_axis_schema(self) -> None:
        target = parse_framing_target(
            payload(),
            expected_device_id=DEVICE_ID,
            received_epoch=100.2,
        )

        self.assertEqual(target.command_x, "RIGHT")
        self.assertEqual(target.command_y, "DOWN")
        self.assertEqual(target.mode, "TRACKING")

    def test_accepts_legacy_combined_direction(self) -> None:
        message = payload()
        message["schema_version"] = "1.0"
        del message["command_x"]
        del message["command_y"]
        message["direction"] = "LEFT_UP"

        target = parse_framing_target(
            message,
            expected_device_id=DEVICE_ID,
            received_epoch=100.2,
        )

        self.assertEqual(target.command_x, "LEFT")
        self.assertEqual(target.command_y, "UP")

    def test_accepts_brief_target_loss_follow_as_tracking(self) -> None:
        message = payload(
            state="TARGET_LOSS_FOLLOW",
            command_x="LEFT",
            command_y="HOLD",
            error_x=-0.2,
            error_y=0.0,
        )

        target = parse_framing_target(
            message,
            expected_device_id=DEVICE_ID,
            received_epoch=100.2,
        )

        self.assertEqual(target.mode, "TRACKING")
        self.assertEqual(target.command_x, "LEFT")

    def test_rejects_expired_message(self) -> None:
        with self.assertRaisesRegex(ValueError, "expired"):
            parse_framing_target(
                payload(),
                expected_device_id=DEVICE_ID,
                received_epoch=100.501,
            )

    def test_rejects_wrong_device(self) -> None:
        with self.assertRaisesRegex(ValueError, "device_id"):
            parse_framing_target(
                payload(),
                expected_device_id="different-device",
                received_epoch=100.1,
            )


class AxisConfigurationTests(unittest.TestCase):
    def test_defaults_limit_pan_to_90_and_tilt_to_the_mount_stop(self) -> None:
        with (
            patch.dict(os.environ, {"DEVICE_ID": DEVICE_ID}, clear=True),
            patch.object(sys, "argv", ["servo_controller.py"]),
        ):
            pan, tilt = build_axis_configs(parse_args())

        self.assertEqual((pan.minimum_deg, pan.maximum_deg), (-90.0, 90.0))
        self.assertEqual((tilt.minimum_deg, tilt.maximum_deg), (0.0, 110.0))
        self.assertEqual((pan.park_deg, tilt.park_deg), (0.0, 0.0))
        self.assertEqual(
            (pan.minimum_pulse_us, pan.maximum_pulse_us),
            (495.0, 2505.0),
        )

    def test_defaults_park_both_axes_at_the_mounted_zero(self) -> None:
        # The horns were seated so that these pulses are where the linkage
        # rests without power. Applying servo power must not move it.
        with (
            patch.dict(os.environ, {"DEVICE_ID": DEVICE_ID}, clear=True),
            patch.object(sys, "argv", ["servo_controller.py"]),
        ):
            pan, tilt = build_axis_configs(parse_args())

        self.assertAlmostEqual(pan.pulse_for_position(pan.park_deg), 1500.0)
        self.assertAlmostEqual(tilt.pulse_for_position(tilt.park_deg), 611.0)

    def test_defaults_map_logical_degrees_onto_physical_degrees(self) -> None:
        # 495..2505us spans 180 physical degrees at 11.1111us per degree, so a
        # logical degree is a physical one. PAN turns right on a falling pulse.
        with (
            patch.dict(os.environ, {"DEVICE_ID": DEVICE_ID}, clear=True),
            patch.object(sys, "argv", ["servo_controller.py"]),
        ):
            pan, tilt = build_axis_configs(parse_args())

        self.assertEqual(pan.pulse_direction, -1)
        self.assertEqual(tilt.pulse_direction, 1)
        self.assertAlmostEqual(pan.pulse_for_position(90.0), 500.001)
        self.assertAlmostEqual(pan.pulse_for_position(-90.0), 2499.999)
        self.assertAlmostEqual(tilt.pulse_for_position(110.0), 1833.221)

    def test_pan_90_does_not_fit_the_old_narrow_pulse_guard(self) -> None:
        # PAN +-90 lands exactly on 1000 and 2000us, and the rounding of
        # 5.555556us per degree pushes it just outside. The guard was widened
        # to the SG90 datasheet range for this reason.
        environment = {
            "DEVICE_ID": DEVICE_ID,
            "SERVO_MINIMUM_PULSE_US": "1000",
            "SERVO_MAXIMUM_PULSE_US": "2000",
        }
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(sys, "argv", ["servo_controller.py"]),
            self.assertRaises(ValueError),
        ):
            build_axis_configs(parse_args())

    def test_startup_position_defaults_to_park(self) -> None:
        with (
            patch.dict(os.environ, {"DEVICE_ID": DEVICE_ID}, clear=True),
            patch.object(sys, "argv", ["servo_controller.py"]),
        ):
            self.assertEqual(parse_args().startup_position, "park")

    def test_start_armed_defaults_to_true(self) -> None:
        with (
            patch.dict(os.environ, {"DEVICE_ID": DEVICE_ID}, clear=True),
            patch.object(sys, "argv", ["servo_controller.py"]),
        ):
            self.assertTrue(parse_args().start_armed)

    def test_start_armed_can_be_disabled_for_manual_power_up(self) -> None:
        environment = {"DEVICE_ID": DEVICE_ID, "SERVO_START_ARMED": "false"}
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(sys, "argv", ["servo_controller.py"]),
        ):
            self.assertFalse(parse_args().start_armed)

    def test_startup_position_can_use_persisted_state(self) -> None:
        environment = {
            "DEVICE_ID": DEVICE_ID,
            "SERVO_STARTUP_POSITION": "persisted",
        }
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(sys, "argv", ["servo_controller.py"]),
        ):
            self.assertEqual(parse_args().startup_position, "persisted")

    def test_nominal_message_interval_defaults_to_the_publisher_rate(
        self,
    ) -> None:
        with (
            patch.dict(os.environ, {"DEVICE_ID": DEVICE_ID}, clear=True),
            patch.object(sys, "argv", ["servo_controller.py"]),
        ):
            self.assertAlmostEqual(
                parse_args().nominal_message_interval,
                0.1,
            )

    def test_nominal_message_interval_must_be_positive(self) -> None:
        environment = {
            "DEVICE_ID": DEVICE_ID,
            "SERVO_NOMINAL_MESSAGE_INTERVAL_SECONDS": "0",
        }
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(sys, "argv", ["servo_controller.py"]),
            patch.object(sys, "stderr", io.StringIO()),
            self.assertRaises(SystemExit),
        ):
            parse_args()

    def test_tilt_supports_symmetric_limits_around_home(self) -> None:
        # The deployed TILT sits at one end of its travel, but nothing in the
        # axis code assumes that. A mount that can move both ways only needs a
        # home pulse with room on either side.
        environment = {
            "DEVICE_ID": DEVICE_ID,
            "SERVO_TILT_MIN_DEG": "-20",
            "SERVO_TILT_MAX_DEG": "20",
            "SERVO_TILT_PARK_DEG": "0",
            "SERVO_TILT_PULSE_DIRECTION": "1",
            "SERVO_TILT_HOME_PULSE_US": "1500",
        }
        with (
            patch.dict(os.environ, environment, clear=False),
            patch.object(sys, "argv", ["servo_controller.py"]),
        ):
            _, tilt = build_axis_configs(parse_args())

        self.assertEqual(tilt.minimum_deg, -20.0)
        self.assertEqual(tilt.home_deg, 0.0)
        self.assertEqual(tilt.park_deg, 0.0)
        self.assertEqual(tilt.maximum_deg, 20.0)
        self.assertEqual(tilt.pulse_direction, 1)
        self.assertAlmostEqual(tilt.pulse_for_position(-20.0), 1277.778)
        self.assertAlmostEqual(tilt.pulse_for_position(20.0), 1722.222)


class PositionPersistenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.pan = axis("PAN", channel=0, minimum=-80.0, maximum=80.0)
        self.tilt = axis("TILT", channel=1, minimum=-80.0, maximum=80.0)

    def test_round_trip_saved_position(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "servo-position.json"
            save_position_atomic(
                path,
                device_id=DEVICE_ID,
                pan_deg=37.25,
                tilt_deg=-14.5,
                saved_at_epoch=100.0,
            )

            restored = load_saved_position(
                path,
                expected_device_id=DEVICE_ID,
                pan=self.pan,
                tilt=self.tilt,
                now_epoch=110.0,
                maximum_age_seconds=60.0,
            )

        self.assertEqual(restored, (37.25, -14.5))

    def test_missing_state_keeps_startup_uninitialized(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            restored = load_saved_position(
                Path(directory) / "missing.json",
                expected_device_id=DEVICE_ID,
                pan=self.pan,
                tilt=self.tilt,
                now_epoch=100.0,
                maximum_age_seconds=60.0,
            )

        self.assertIsNone(restored)

    def test_rejects_stale_or_out_of_range_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "servo-position.json"
            save_position_atomic(
                path,
                device_id=DEVICE_ID,
                pan_deg=81.0,
                tilt_deg=0.0,
                saved_at_epoch=100.0,
            )
            with self.assertRaisesRegex(ValueError, "outside configured limits"):
                load_saved_position(
                    path,
                    expected_device_id=DEVICE_ID,
                    pan=self.pan,
                    tilt=self.tilt,
                    now_epoch=110.0,
                    maximum_age_seconds=60.0,
                )

            save_position_atomic(
                path,
                device_id=DEVICE_ID,
                pan_deg=0.0,
                tilt_deg=0.0,
                saved_at_epoch=100.0,
            )
            with self.assertRaisesRegex(ValueError, "stale"):
                load_saved_position(
                    path,
                    expected_device_id=DEVICE_ID,
                    pan=self.pan,
                    tilt=self.tilt,
                    now_epoch=200.0,
                    maximum_age_seconds=60.0,
                )


class Pca9685OutputTests(unittest.TestCase):
    def test_configures_50hz_and_writes_both_servo_channels(self) -> None:
        bus = FakeSmbus(7)
        fake_smbus_module = types.SimpleNamespace(SMBus=lambda bus_number: bus)
        pan = axis("PAN", channel=0, minimum=-40.0, maximum=40.0)
        tilt = axis("TILT", channel=1, minimum=0.0, maximum=80.0)

        with patch.dict(sys.modules, {"smbus2": fake_smbus_module}):
            output = Pca9685ServoOutput(
                i2c_bus=7,
                address=0x40,
                frequency_hz=50.0,
                oscillator_hz=25_000_000.0,
                pan=pan,
                tilt=tilt,
            )
            output.write_positions(0.0, 0.0)
            output.close()

        self.assertEqual(bus.bus_number, 7)
        self.assertIn((0x40, Pca9685ServoOutput.PRE_SCALE, 121), bus.byte_writes)
        self.assertEqual(bus.block_writes[0], (0x40, 0x06, [0, 0, 0, 0x10]))
        self.assertEqual(bus.block_writes[1], (0x40, 0x0A, [0, 0, 0, 0x10]))
        self.assertEqual(bus.block_writes[2], (0x40, 0x06, [0, 0, 51, 1]))
        self.assertEqual(bus.block_writes[3], (0x40, 0x0A, [0, 0, 51, 1]))
        self.assertTrue(bus.closed)

    def test_wakes_controller_when_mode1_initially_has_sleep_set(self) -> None:
        bus = FakeSmbus(7, initial_mode1=0x11)
        fake_smbus_module = types.SimpleNamespace(SMBus=lambda bus_number: bus)
        pan = axis("PAN", channel=0, minimum=-10.0, maximum=10.0)
        tilt = axis("TILT", channel=1, minimum=0.0, maximum=10.0)

        with patch.dict(sys.modules, {"smbus2": fake_smbus_module}):
            output = Pca9685ServoOutput(
                i2c_bus=7,
                address=0x60,
                frequency_hz=50.0,
                oscillator_hz=25_000_000.0,
                pan=pan,
                tilt=tilt,
            )
            output.close()

        mode1_writes = [
            value
            for address, register, value in bus.byte_writes
            if address == 0x60 and register == Pca9685ServoOutput.MODE1
        ]
        self.assertEqual(mode1_writes, [0x11, 0x21])
        self.assertEqual(mode1_writes[-1] & Pca9685ServoOutput.MODE1_SLEEP, 0)
        restart_writes = [
            value
            for value in mode1_writes
            if value & Pca9685ServoOutput.MODE1_RESTART
        ]
        self.assertEqual(restart_writes, [])


class ServoControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.output = RecordingOutput()
        self.controller = ServoController(
            pan=axis("PAN", channel=0, minimum=-80.0, maximum=80.0),
            tilt=axis("TILT", channel=1, minimum=-80.0, maximum=80.0),
            output=self.output,
            expected_device_id=DEVICE_ID,
            message_timeout_seconds=0.75,
        )

    def accept(
        self,
        message: dict[str, object],
        *,
        received_epoch: float,
        received_monotonic: float,
    ) -> None:
        self.controller.accept_payload(
            message,
            received_epoch=received_epoch,
            received_monotonic=received_monotonic,
        )

    def test_tracking_moves_both_axes_with_speed_limit(self) -> None:
        self.accept(payload(), received_epoch=100.1, received_monotonic=10.0)

        wrote = self.controller.tick(10.1)

        self.assertTrue(wrote)
        self.assertEqual(self.output.positions, [(0.0, 0.0)])
        self.controller.tick(10.2)
        self.assertAlmostEqual(self.controller.current_pan_deg, 2.0)
        self.assertAlmostEqual(self.controller.current_tilt_deg, 1.0)
        self.assertEqual(self.controller.mode, "TRACKING")

    def test_disarmed_controller_ignores_targets_until_armed(self) -> None:
        output = RecordingOutput()
        controller = ServoController(
            pan=axis("PAN", channel=0, minimum=-80.0, maximum=80.0),
            tilt=axis("TILT", channel=1, minimum=-80.0, maximum=80.0),
            output=output,
            expected_device_id=DEVICE_ID,
            message_timeout_seconds=0.75,
            initial_position=(0.0, -50.0),
            output_armed=False,
        )
        controller.accept_payload(
            payload(),
            received_epoch=100.1,
            received_monotonic=10.0,
        )

        self.assertFalse(controller.tick(10.1))
        self.assertFalse(controller.tick(10.2))
        self.assertEqual(output.positions, [])
        self.assertEqual(controller.mode, "STARTUP_WAITING")
        self.assertEqual(controller.position_snapshot(), (0.0, -50.0))

        self.assertTrue(controller.arm())

        self.assertEqual(controller.mode, "HOLD")
        self.assertEqual(controller.position_snapshot(), (0.0, -50.0))
        self.assertFalse(controller.arm())

    def test_arming_follows_targets_from_the_held_position(self) -> None:
        output = RecordingOutput()
        controller = ServoController(
            pan=axis("PAN", channel=0, minimum=-80.0, maximum=80.0),
            tilt=axis("TILT", channel=1, minimum=-80.0, maximum=80.0),
            output=output,
            expected_device_id=DEVICE_ID,
            message_timeout_seconds=0.75,
            initial_position=(0.0, -50.0),
            output_armed=False,
        )
        controller.arm()
        controller.accept_payload(
            payload(),
            received_epoch=100.1,
            received_monotonic=10.0,
        )

        self.assertTrue(controller.tick(10.1))
        self.assertEqual(output.positions, [(0.0, -50.0)])

    def test_arm_is_refused_when_no_startup_position_was_restored(self) -> None:
        output = RecordingOutput()
        controller = ServoController(
            pan=axis("PAN", channel=0, minimum=-80.0, maximum=80.0),
            tilt=axis("TILT", channel=1, minimum=-80.0, maximum=80.0),
            output=output,
            expected_device_id=DEVICE_ID,
            message_timeout_seconds=0.75,
            output_armed=False,
        )
        controller.accept_payload(
            payload(),
            received_epoch=100.1,
            received_monotonic=10.0,
        )

        self.assertFalse(controller.arm())

        self.assertFalse(controller.output_armed)
        self.assertEqual(controller.mode, "STARTUP_WAITING")
        self.assertFalse(controller.tick(10.1))
        self.assertEqual(output.positions, [])

    def test_park_startup_still_arms_because_the_position_is_known(self) -> None:
        output = RecordingOutput()
        controller = ServoController(
            pan=axis("PAN", channel=0, minimum=-80.0, maximum=80.0),
            tilt=axis(
                "TILT",
                channel=1,
                minimum=-80.0,
                maximum=80.0,
                park=-50.0,
            ),
            output=output,
            expected_device_id=DEVICE_ID,
            message_timeout_seconds=0.75,
            initial_position=(0.0, -50.0),
            output_armed=False,
        )

        self.assertTrue(controller.startup_position_restored)
        self.assertTrue(controller.arm())
        self.assertTrue(controller.output_armed)
        self.assertEqual(controller.mode, "HOLD")

    def test_first_pulse_exactly_restores_saved_position(self) -> None:
        output = RecordingOutput()
        controller = ServoController(
            pan=axis("PAN", channel=0, minimum=-80.0, maximum=80.0),
            tilt=axis("TILT", channel=1, minimum=-80.0, maximum=80.0),
            output=output,
            expected_device_id=DEVICE_ID,
            message_timeout_seconds=0.75,
            initial_position=(37.25, -14.5),
        )
        controller.accept_payload(
            payload(),
            received_epoch=100.1,
            received_monotonic=10.0,
        )

        controller.tick(10.1)

        self.assertEqual(output.positions, [(37.25, -14.5)])
        self.assertTrue(controller.startup_position_restored)

    def test_missing_position_keeps_hardware_output_disarmed(self) -> None:
        output = RecordingOutput()
        controller = ServoController(
            pan=axis("PAN", channel=0, minimum=-80.0, maximum=80.0),
            tilt=axis("TILT", channel=1, minimum=-80.0, maximum=80.0),
            output=output,
            expected_device_id=DEVICE_ID,
            message_timeout_seconds=0.75,
            output_armed=False,
        )
        controller.accept_payload(
            payload(),
            received_epoch=100.1,
            received_monotonic=10.0,
        )

        wrote = controller.tick(10.1)
        status = controller.status_payload(hardware_enabled=True)

        self.assertFalse(wrote)
        self.assertEqual(output.positions, [])
        self.assertEqual(status["state"], "STARTUP_WAITING")
        self.assertFalse(status["output_armed"])
        self.assertFalse(status["startup_position_restored"])

    def test_shutdown_home_moves_safely_without_mqtt_message(self) -> None:
        output = RecordingOutput()
        controller = ServoController(
            pan=axis("PAN", channel=0, minimum=-80.0, maximum=80.0),
            tilt=axis("TILT", channel=1, minimum=-80.0, maximum=80.0),
            output=output,
            expected_device_id=DEVICE_ID,
            message_timeout_seconds=0.75,
            initial_position=(4.0, -2.0),
        )

        controller.request_home()
        controller.tick(10.0)
        controller.tick(10.1)
        controller.tick(10.2)

        self.assertTrue(controller.is_at_home())
        self.assertEqual(output.positions[0], (4.0, -2.0))
        self.assertAlmostEqual(output.positions[-1][0], 0.0)
        self.assertAlmostEqual(output.positions[-1][1], 0.0)

    def test_hold_ignores_retained_errors(self) -> None:
        self.accept(payload(), received_epoch=100.1, received_monotonic=10.0)
        self.controller.tick(10.1)
        held_pan = self.controller.current_pan_deg
        held_tilt = self.controller.current_tilt_deg
        hold = payload(
            state="NO_TARGET_HOLD",
            command_x="HOLD",
            command_y="HOLD",
            error_x=0.9,
            error_y=0.8,
            sequence=2,
            sent_at_epoch=100.2,
        )

        self.accept(hold, received_epoch=100.3, received_monotonic=10.2)
        self.controller.tick(10.3)

        self.assertEqual(self.controller.mode, "HOLD")
        self.assertEqual(self.controller.current_pan_deg, held_pan)
        self.assertEqual(self.controller.current_tilt_deg, held_tilt)
        self.assertEqual(self.controller.last_error_x, 0.9)
        self.assertEqual(self.controller.last_error_y, 0.8)

    def test_axis_hold_cancels_remaining_motion_inside_deadzone(self) -> None:
        moving = payload(error_x=1.0, error_y=0.0)
        self.accept(moving, received_epoch=100.1, received_monotonic=10.0)
        self.controller.tick(10.1)
        self.assertGreater(
            self.controller.target_pan_deg,
            self.controller.current_pan_deg,
        )
        hold_x = payload(
            command_x="HOLD",
            command_y="HOLD",
            error_x=0.02,
            error_y=0.0,
            sequence=2,
            sent_at_epoch=100.2,
        )

        self.accept(hold_x, received_epoch=100.3, received_monotonic=10.2)
        held_pan = self.controller.current_pan_deg
        self.controller.tick(10.3)

        self.assertEqual(self.controller.current_pan_deg, held_pan)
        self.assertEqual(self.controller.target_pan_deg, held_pan)

    def test_home_returns_both_axes(self) -> None:
        self.accept(payload(), received_epoch=100.1, received_monotonic=10.0)
        self.controller.tick(10.1)
        home = payload(
            state="RETURN_HOME",
            command_x="HOME",
            command_y="HOME",
            error_x=0.0,
            error_y=0.0,
            sequence=2,
            sent_at_epoch=100.2,
        )

        self.accept(home, received_epoch=100.3, received_monotonic=10.2)
        self.controller.tick(10.25)

        self.assertEqual(self.controller.mode, "HOME")
        self.assertAlmostEqual(self.controller.current_pan_deg, 0.0)
        self.assertAlmostEqual(self.controller.current_tilt_deg, 0.0)

    def test_home_uses_axis_specific_park_positions(self) -> None:
        output = RecordingOutput()
        controller = ServoController(
            pan=axis(
                "PAN",
                channel=0,
                minimum=-80.0,
                maximum=80.0,
                park=0.0,
            ),
            tilt=axis(
                "TILT",
                channel=1,
                minimum=-50.0,
                maximum=80.0,
                park=-50.0,
            ),
            output=output,
            expected_device_id=DEVICE_ID,
            message_timeout_seconds=0.75,
            initial_position=(20.0, 10.0),
        )
        controller.accept_payload(
            payload(
                state="RETURN_HOME",
                command_x="HOME",
                command_y="HOME",
            ),
            received_epoch=100.1,
            received_monotonic=10.0,
        )

        for index in range(40):
            controller.tick(10.0 + index * 0.1)

        self.assertTrue(controller.is_at_home())
        self.assertAlmostEqual(controller.current_pan_deg, 0.0)
        self.assertAlmostEqual(controller.current_tilt_deg, -50.0)
        status = controller.status_payload(hardware_enabled=False)
        self.assertEqual(status["pan_park_deg"], 0.0)
        self.assertEqual(status["tilt_park_deg"], -50.0)

    def test_message_timeout_forces_hold(self) -> None:
        self.accept(payload(), received_epoch=100.1, received_monotonic=10.0)
        self.controller.tick(10.1)

        self.controller.tick(10.8)

        self.assertEqual(self.controller.mode, "HOLD")
        self.assertEqual(
            self.controller.target_pan_deg,
            self.controller.current_pan_deg,
        )
        self.assertEqual(
            self.controller.target_tilt_deg,
            self.controller.current_tilt_deg,
        )
        self.assertEqual(self.controller.timeout_holds, 1)

    def test_status_includes_dashboard_limits_and_current_pulses(self) -> None:
        self.accept(payload(), received_epoch=100.1, received_monotonic=10.0)
        self.controller.tick(10.1)

        status = self.controller.status_payload(hardware_enabled=False)

        self.assertEqual(status["pan_minimum_deg"], -80.0)
        self.assertEqual(status["pan_maximum_deg"], 80.0)
        self.assertEqual(status["tilt_minimum_deg"], -80.0)
        self.assertEqual(status["tilt_maximum_deg"], 80.0)
        self.assertAlmostEqual(
            status["pan_pulse_us"],
            1500.0 + status["pan_deg"] * 5.0,
        )
        self.assertAlmostEqual(
            status["tilt_pulse_us"],
            1500.0 + status["tilt_deg"] * 5.0,
        )

    def test_rejects_out_of_order_message(self) -> None:
        message = payload()
        self.accept(message, received_epoch=100.1, received_monotonic=10.0)

        with self.assertRaisesRegex(ValueError, "out-of-order"):
            self.accept(message, received_epoch=100.2, received_monotonic=10.1)

        self.assertEqual(self.controller.rejected_messages, 1)

    def test_pan_and_tilt_stay_inside_logical_limits(self) -> None:
        for index in range(1, 201):
            sent = 100.0 + index * 0.1
            self.accept(
                payload(sequence=index, sent_at_epoch=sent),
                received_epoch=sent + 0.01,
                received_monotonic=10.0 + index * 0.1,
            )

        self.assertEqual(self.controller.target_pan_deg, 80.0)
        self.assertEqual(self.controller.target_tilt_deg, 80.0)

    def test_tilt_up_commands_stop_at_mechanical_safe_limit(self) -> None:
        controller = ServoController(
            pan=axis("PAN", channel=0, minimum=-80.0, maximum=80.0),
            tilt=axis(
                "TILT",
                channel=1,
                minimum=-50.0,
                maximum=80.0,
                park=-50.0,
            ),
            output=RecordingOutput(),
            expected_device_id=DEVICE_ID,
            message_timeout_seconds=0.75,
            initial_position=(0.0, 0.0),
        )
        for index in range(1, 201):
            sent = 100.0 + index * 0.1
            controller.accept_payload(
                payload(
                    command_y="UP",
                    error_y=-1.0,
                    sequence=index,
                    sent_at_epoch=sent,
                ),
                received_epoch=sent + 0.01,
                received_monotonic=10.0 + index * 0.1,
            )

        self.assertEqual(controller.target_tilt_deg, -50.0)


if __name__ == "__main__":
    unittest.main()
