"""Unit tests for MQTT validation and hardware-independent servo control."""

from __future__ import annotations

from datetime import datetime, timezone
import sys
import types
import unittest
from unittest.mock import patch

from servo_controller import (
    AxisConfig,
    Pca9685ServoOutput,
    ServoController,
    parse_framing_target,
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
) -> AxisConfig:
    return AxisConfig(
        name=name,
        channel=channel,
        minimum_deg=minimum,
        home_deg=0.0,
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
        self.assertEqual(mode1_writes, [0x11, 0x21, 0xA1])
        self.assertEqual(mode1_writes[-1] & Pca9685ServoOutput.MODE1_SLEEP, 0)


class ServoControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.output = RecordingOutput()
        self.controller = ServoController(
            pan=axis("PAN", channel=0, minimum=-40.0, maximum=40.0),
            tilt=axis("TILT", channel=1, minimum=0.0, maximum=80.0),
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
        self.assertAlmostEqual(self.controller.current_pan_deg, 2.0)
        self.assertAlmostEqual(self.controller.current_tilt_deg, 1.0)
        self.assertEqual(self.controller.mode, "TRACKING")

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

        self.assertEqual(status["pan_minimum_deg"], -40.0)
        self.assertEqual(status["pan_maximum_deg"], 40.0)
        self.assertEqual(status["tilt_minimum_deg"], 0.0)
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

        self.assertEqual(self.controller.target_pan_deg, 40.0)
        self.assertEqual(self.controller.target_tilt_deg, 80.0)


if __name__ == "__main__":
    unittest.main()
