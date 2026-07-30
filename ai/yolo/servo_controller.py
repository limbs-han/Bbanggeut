"""Translate local MQTT auto-framing targets into safe PCA9685 servo motion.

The controller keeps camera-space positions separate from raw servo pulses:

* PAN uses -40 degrees (left) through +40 degrees (right).
* TILT limits are configurable around 0 degrees (HOME); negative/positive
  limits allow equal travel in both directions when the linkage permits it.
* Pulse direction and calibration remain deployment settings because linkage
  orientation and individual SG90 endpoints vary.

Hardware output is disabled unless SERVO_ENABLE_HARDWARE=true or
--enable-hardware is supplied.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
import os
import signal
import threading
import time
from typing import Any, Protocol


TRACKING_STATES = {"TRACKING"}
HOLD_STATES = {"HOLD", "NO_TARGET_HOLD"}
HOME_STATES = {"HOME", "RETURN_HOME"}
X_COMMANDS = {"LEFT", "RIGHT", "HOLD", "HOME"}
Y_COMMANDS = {"UP", "DOWN", "HOLD", "HOME"}


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(value, high))


def env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    normalized = raw.strip().casefold()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"{name} must be true or false")


def parse_int_auto(value: str) -> int:
    return int(value, 0)


def parse_utc_timestamp(value: Any) -> float:
    if not isinstance(value, str) or not value:
        raise ValueError("sent_at must be a non-empty UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError("sent_at must be an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise ValueError("sent_at must include a timezone")
    return parsed.timestamp()


def finite_float(payload: dict[str, Any], key: str) -> float:
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{key} must be a number")
    result = float(value)
    if not math.isfinite(result):
        raise ValueError(f"{key} must be finite")
    return result


def split_legacy_direction(direction: Any) -> tuple[str, str]:
    if not isinstance(direction, str):
        raise ValueError("direction must be a string")
    normalized = direction.strip().upper()
    if normalized == "HOLD":
        return "HOLD", "HOLD"
    if normalized == "HOME":
        return "HOME", "HOME"

    command_x = "HOLD"
    command_y = "HOLD"
    for part in normalized.split("_"):
        if part in {"LEFT", "RIGHT"}:
            if command_x != "HOLD":
                raise ValueError("direction contains more than one horizontal command")
            command_x = part
        elif part in {"UP", "DOWN"}:
            if command_y != "HOLD":
                raise ValueError("direction contains more than one vertical command")
            command_y = part
        else:
            raise ValueError(f"unsupported direction: {direction}")
    return command_x, command_y


@dataclass(frozen=True)
class FramingTarget:
    schema_version: str
    device_id: str
    sequence: int
    sent_at_epoch: float
    ttl_ms: int
    state: str
    command_x: str
    command_y: str
    error_x: float
    error_y: float

    @property
    def mode(self) -> str:
        if self.state in TRACKING_STATES:
            return "TRACKING"
        if self.state in HOLD_STATES:
            return "HOLD"
        return "HOME"


def parse_framing_target(
    payload: dict[str, Any],
    *,
    expected_device_id: str,
    received_epoch: float,
) -> FramingTarget:
    if not isinstance(payload, dict):
        raise ValueError("payload must be a JSON object")

    schema_version = str(payload.get("schema_version", ""))
    if schema_version not in {"1.0", "1.1"}:
        raise ValueError(f"unsupported schema_version: {schema_version}")

    device_id = payload.get("device_id")
    if device_id != expected_device_id:
        raise ValueError("device_id does not match this controller")

    sequence = payload.get("sequence")
    if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 0:
        raise ValueError("sequence must be a non-negative integer")

    ttl_ms = payload.get("ttl_ms")
    if isinstance(ttl_ms, bool) or not isinstance(ttl_ms, int):
        raise ValueError("ttl_ms must be an integer")
    if not 1 <= ttl_ms <= 5_000:
        raise ValueError("ttl_ms must be between 1 and 5000")

    sent_at_epoch = parse_utc_timestamp(payload.get("sent_at"))
    age_ms = (received_epoch - sent_at_epoch) * 1_000.0
    if age_ms > ttl_ms:
        raise ValueError("message TTL has expired")
    if age_ms < -5_000:
        raise ValueError("sent_at is too far in the future")

    state = str(payload.get("state", "")).strip().upper()
    if state not in TRACKING_STATES | HOLD_STATES | HOME_STATES:
        raise ValueError(f"unsupported state: {state}")

    error_x = finite_float(payload, "error_x")
    error_y = finite_float(payload, "error_y")
    if not -1.0 <= error_x <= 1.0 or not -1.0 <= error_y <= 1.0:
        raise ValueError("error_x and error_y must be between -1.0 and 1.0")

    if "command_x" in payload or "command_y" in payload:
        command_x = str(payload.get("command_x", "")).strip().upper()
        command_y = str(payload.get("command_y", "")).strip().upper()
    else:
        command_x, command_y = split_legacy_direction(payload.get("direction"))

    if command_x not in X_COMMANDS:
        raise ValueError(f"unsupported command_x: {command_x}")
    if command_y not in Y_COMMANDS:
        raise ValueError(f"unsupported command_y: {command_y}")

    if state in HOLD_STATES and (command_x != "HOLD" or command_y != "HOLD"):
        raise ValueError("HOLD state requires HOLD on both axes")
    if state in HOME_STATES and (command_x != "HOME" or command_y != "HOME"):
        raise ValueError("HOME state requires HOME on both axes")
    if state in TRACKING_STATES and (
        command_x == "HOME" or command_y == "HOME"
    ):
        raise ValueError("TRACKING state cannot contain a HOME axis command")

    return FramingTarget(
        schema_version=schema_version,
        device_id=device_id,
        sequence=sequence,
        sent_at_epoch=sent_at_epoch,
        ttl_ms=ttl_ms,
        state=state,
        command_x=command_x,
        command_y=command_y,
        error_x=error_x,
        error_y=error_y,
    )


@dataclass(frozen=True)
class AxisConfig:
    name: str
    channel: int
    minimum_deg: float
    home_deg: float
    maximum_deg: float
    home_pulse_us: float
    pulse_us_per_degree: float
    pulse_direction: int
    response_gain_deg_per_second: float
    max_speed_deg_per_second: float
    minimum_pulse_us: float
    maximum_pulse_us: float

    def validate(self) -> None:
        if not 0 <= self.channel <= 15:
            raise ValueError(f"{self.name} channel must be between 0 and 15")
        if not self.minimum_deg <= self.home_deg <= self.maximum_deg:
            raise ValueError(
                f"{self.name} limits must satisfy minimum <= home <= maximum"
            )
        if self.pulse_direction not in {-1, 1}:
            raise ValueError(f"{self.name} pulse direction must be -1 or 1")
        if self.pulse_us_per_degree <= 0:
            raise ValueError(f"{self.name} pulse_us_per_degree must be positive")
        if self.response_gain_deg_per_second <= 0:
            raise ValueError(f"{self.name} response gain must be positive")
        if self.max_speed_deg_per_second <= 0:
            raise ValueError(f"{self.name} maximum speed must be positive")
        if self.minimum_pulse_us >= self.maximum_pulse_us:
            raise ValueError(f"{self.name} pulse limits are invalid")
        for position in (self.minimum_deg, self.home_deg, self.maximum_deg):
            pulse = self.pulse_for_position(position)
            if not self.minimum_pulse_us <= pulse <= self.maximum_pulse_us:
                raise ValueError(
                    f"{self.name} position {position} produces unsafe pulse {pulse:.1f}us"
                )

    def pulse_for_position(self, position_deg: float) -> float:
        offset = position_deg - self.home_deg
        return self.home_pulse_us + (
            self.pulse_direction * offset * self.pulse_us_per_degree
        )


class ServoOutput(Protocol):
    def write_positions(self, pan_deg: float, tilt_deg: float) -> None: ...

    def close(self) -> None: ...


class DryRunServoOutput:
    def __init__(self) -> None:
        self.last_positions: tuple[float, float] | None = None

    def write_positions(self, pan_deg: float, tilt_deg: float) -> None:
        positions = (round(pan_deg, 3), round(tilt_deg, 3))
        if positions != self.last_positions:
            print(
                f"DRY-RUN servo position: pan={positions[0]:+.2f}deg "
                f"tilt={positions[1]:+.2f}deg"
            )
            self.last_positions = positions

    def close(self) -> None:
        return


class Pca9685ServoOutput:
    MODE1 = 0x00
    MODE2 = 0x01
    LED0_ON_L = 0x06
    PRE_SCALE = 0xFE
    MODE1_RESTART = 0x80
    MODE1_AUTO_INCREMENT = 0x20
    MODE1_SLEEP = 0x10
    MODE2_OUTDRV = 0x04
    FULL_OFF = 0x10

    def __init__(
        self,
        *,
        i2c_bus: int,
        address: int,
        frequency_hz: float,
        oscillator_hz: float,
        pan: AxisConfig,
        tilt: AxisConfig,
    ) -> None:
        try:
            from smbus2 import SMBus
        except ImportError as exc:
            raise SystemExit(
                "smbus2 is missing. Install requirements-servo-controller.txt."
            ) from exc

        if pan.channel == tilt.channel:
            raise ValueError("PAN and TILT must use different PCA9685 channels")
        if not 0x03 <= address <= 0x77:
            raise ValueError("PCA9685 I2C address must be between 0x03 and 0x77")
        if not 40.0 <= frequency_hz <= 60.0:
            raise ValueError("SG90 PWM frequency must be between 40 and 60Hz")

        self._bus = SMBus(i2c_bus)
        self._address = address
        self._frequency_hz = frequency_hz
        self._pan = pan
        self._tilt = tilt
        self._configure_frequency(frequency_hz, oscillator_hz)
        self._disable_channel(self._pan.channel)
        self._disable_channel(self._tilt.channel)

    def _configure_frequency(
        self, frequency_hz: float, oscillator_hz: float
    ) -> None:
        prescale = round(oscillator_hz / (4096.0 * frequency_hz)) - 1
        if not 3 <= prescale <= 255:
            raise ValueError("PCA9685 prescale is outside the supported range")

        old_mode = self._bus.read_byte_data(self._address, self.MODE1)
        sleep_mode = (old_mode & ~self.MODE1_RESTART) | self.MODE1_SLEEP
        wake_mode = (
            old_mode
            & ~(self.MODE1_RESTART | self.MODE1_SLEEP)
            | self.MODE1_AUTO_INCREMENT
        )
        self._bus.write_byte_data(self._address, self.MODE1, sleep_mode)
        self._bus.write_byte_data(self._address, self.PRE_SCALE, prescale)
        self._bus.write_byte_data(self._address, self.MODE1, wake_mode)
        time.sleep(0.005)
        self._bus.write_byte_data(
            self._address,
            self.MODE1,
            wake_mode | self.MODE1_RESTART,
        )
        self._bus.write_byte_data(self._address, self.MODE2, self.MODE2_OUTDRV)

    def _write_pulse(self, channel: int, pulse_us: float) -> None:
        counts = round(pulse_us * self._frequency_hz * 4096.0 / 1_000_000.0)
        counts = int(clamp(float(counts), 1.0, 4095.0))
        register = self.LED0_ON_L + 4 * channel
        self._bus.write_i2c_block_data(
            self._address,
            register,
            [0, 0, counts & 0xFF, (counts >> 8) & 0x0F],
        )

    def _disable_channel(self, channel: int) -> None:
        register = self.LED0_ON_L + 4 * channel
        self._bus.write_i2c_block_data(
            self._address,
            register,
            [0, 0, 0, self.FULL_OFF],
        )

    def write_positions(self, pan_deg: float, tilt_deg: float) -> None:
        self._write_pulse(self._pan.channel, self._pan.pulse_for_position(pan_deg))
        self._write_pulse(
            self._tilt.channel,
            self._tilt.pulse_for_position(tilt_deg),
        )

    def close(self) -> None:
        try:
            self._disable_channel(self._pan.channel)
            self._disable_channel(self._tilt.channel)
        finally:
            self._bus.close()


def move_toward(current: float, target: float, maximum_delta: float) -> float:
    if current < target:
        return min(current + maximum_delta, target)
    if current > target:
        return max(current - maximum_delta, target)
    return current


class ServoController:
    def __init__(
        self,
        *,
        pan: AxisConfig,
        tilt: AxisConfig,
        output: ServoOutput,
        expected_device_id: str,
        message_timeout_seconds: float,
        nominal_message_interval_seconds: float = 0.1,
    ) -> None:
        pan.validate()
        tilt.validate()
        if pan.channel == tilt.channel:
            raise ValueError("PAN and TILT channels must be different")
        if message_timeout_seconds <= 0:
            raise ValueError("message timeout must be positive")
        if nominal_message_interval_seconds <= 0:
            raise ValueError("nominal message interval must be positive")

        self.pan = pan
        self.tilt = tilt
        self.output = output
        self.expected_device_id = expected_device_id
        self.message_timeout_seconds = message_timeout_seconds
        self.nominal_message_interval_seconds = nominal_message_interval_seconds

        self.current_pan_deg = pan.home_deg
        self.current_tilt_deg = tilt.home_deg
        self.target_pan_deg = pan.home_deg
        self.target_tilt_deg = tilt.home_deg
        self.mode = "HOLD"
        self.last_error_x = 0.0
        self.last_error_y = 0.0
        self.last_message_monotonic: float | None = None
        self.last_tick_monotonic: float | None = None
        self.last_order_key: tuple[float, int] | None = None
        self.accepted_messages = 0
        self.rejected_messages = 0
        self.timeout_holds = 0
        self._output_initialized = False
        self._lock = threading.Lock()

    @staticmethod
    def _signed_error(command: str, error: float) -> float:
        if command in {"RIGHT", "DOWN"}:
            return abs(error)
        if command in {"LEFT", "UP"}:
            return -abs(error)
        return 0.0

    def accept_payload(
        self,
        payload: dict[str, Any],
        *,
        received_epoch: float,
        received_monotonic: float,
    ) -> FramingTarget:
        try:
            target = parse_framing_target(
                payload,
                expected_device_id=self.expected_device_id,
                received_epoch=received_epoch,
            )
        except ValueError:
            with self._lock:
                self.rejected_messages += 1
            raise

        with self._lock:
            order_key = (target.sent_at_epoch, target.sequence)
            if self.last_order_key is not None and order_key <= self.last_order_key:
                self.rejected_messages += 1
                raise ValueError("duplicate or out-of-order framing target")

            if self.last_message_monotonic is None:
                message_delta = self.nominal_message_interval_seconds
            else:
                message_delta = clamp(
                    received_monotonic - self.last_message_monotonic,
                    0.0,
                    self.message_timeout_seconds,
                )

            self.last_order_key = order_key
            self.last_message_monotonic = received_monotonic
            self.last_error_x = target.error_x
            self.last_error_y = target.error_y
            self.mode = target.mode
            self.accepted_messages += 1

            if target.mode == "TRACKING":
                pan_error = self._signed_error(target.command_x, target.error_x)
                tilt_error = self._signed_error(target.command_y, target.error_y)
                if target.command_x == "HOLD":
                    self.target_pan_deg = self.current_pan_deg
                else:
                    self.target_pan_deg = clamp(
                        self.target_pan_deg
                        + pan_error
                        * self.pan.response_gain_deg_per_second
                        * message_delta,
                        self.pan.minimum_deg,
                        self.pan.maximum_deg,
                    )
                if target.command_y == "HOLD":
                    self.target_tilt_deg = self.current_tilt_deg
                else:
                    self.target_tilt_deg = clamp(
                        self.target_tilt_deg
                        + tilt_error
                        * self.tilt.response_gain_deg_per_second
                        * message_delta,
                        self.tilt.minimum_deg,
                        self.tilt.maximum_deg,
                    )
            elif target.mode == "HOLD":
                self.target_pan_deg = self.current_pan_deg
                self.target_tilt_deg = self.current_tilt_deg
            else:
                self.target_pan_deg = self.pan.home_deg
                self.target_tilt_deg = self.tilt.home_deg

        return target

    def tick(self, now_monotonic: float) -> bool:
        with self._lock:
            if self.last_message_monotonic is None:
                self.last_tick_monotonic = now_monotonic
                return False

            if (
                now_monotonic - self.last_message_monotonic
                > self.message_timeout_seconds
                and self.mode != "HOLD"
            ):
                self.mode = "HOLD"
                self.target_pan_deg = self.current_pan_deg
                self.target_tilt_deg = self.current_tilt_deg
                self.timeout_holds += 1

            if self.last_tick_monotonic is None:
                elapsed = self.nominal_message_interval_seconds
            else:
                elapsed = clamp(
                    now_monotonic - self.last_tick_monotonic,
                    0.0,
                    0.25,
                )
            self.last_tick_monotonic = now_monotonic

            next_pan = move_toward(
                self.current_pan_deg,
                self.target_pan_deg,
                self.pan.max_speed_deg_per_second * elapsed,
            )
            next_tilt = move_toward(
                self.current_tilt_deg,
                self.target_tilt_deg,
                self.tilt.max_speed_deg_per_second * elapsed,
            )
            changed = (
                abs(next_pan - self.current_pan_deg) >= 0.001
                or abs(next_tilt - self.current_tilt_deg) >= 0.001
            )
            self.current_pan_deg = next_pan
            self.current_tilt_deg = next_tilt
            should_write = changed or not self._output_initialized
            pan_deg = self.current_pan_deg
            tilt_deg = self.current_tilt_deg
            if should_write:
                self._output_initialized = True

        if should_write:
            self.output.write_positions(pan_deg, tilt_deg)
        return should_write

    def status_payload(self, *, hardware_enabled: bool) -> dict[str, Any]:
        with self._lock:
            return {
                "schema_version": "1.0",
                "device_id": self.expected_device_id,
                "sent_at": datetime.now(timezone.utc)
                .isoformat(timespec="milliseconds")
                .replace("+00:00", "Z"),
                "component": "servo_controller",
                "state": self.mode,
                "hardware_enabled": hardware_enabled,
                "pan_deg": round(self.current_pan_deg, 3),
                "tilt_deg": round(self.current_tilt_deg, 3),
                "target_pan_deg": round(self.target_pan_deg, 3),
                "target_tilt_deg": round(self.target_tilt_deg, 3),
                "pan_minimum_deg": self.pan.minimum_deg,
                "pan_maximum_deg": self.pan.maximum_deg,
                "tilt_minimum_deg": self.tilt.minimum_deg,
                "tilt_maximum_deg": self.tilt.maximum_deg,
                "pan_pulse_us": round(
                    self.pan.pulse_for_position(self.current_pan_deg),
                    3,
                ),
                "tilt_pulse_us": round(
                    self.tilt.pulse_for_position(self.current_tilt_deg),
                    3,
                ),
                "error_x": self.last_error_x,
                "error_y": self.last_error_y,
                "accepted_messages": self.accepted_messages,
                "rejected_messages": self.rejected_messages,
                "timeout_holds": self.timeout_holds,
            }

    def close(self) -> None:
        self.output.close()


def build_axis_configs(args: argparse.Namespace) -> tuple[AxisConfig, AxisConfig]:
    pan = AxisConfig(
        name="PAN",
        channel=args.pan_channel,
        minimum_deg=args.pan_min_deg,
        home_deg=0.0,
        maximum_deg=args.pan_max_deg,
        home_pulse_us=args.pan_home_pulse_us,
        pulse_us_per_degree=args.pan_pulse_us_per_degree,
        pulse_direction=args.pan_pulse_direction,
        response_gain_deg_per_second=args.pan_response_gain,
        max_speed_deg_per_second=args.pan_max_speed,
        minimum_pulse_us=args.minimum_pulse_us,
        maximum_pulse_us=args.maximum_pulse_us,
    )
    tilt = AxisConfig(
        name="TILT",
        channel=args.tilt_channel,
        minimum_deg=args.tilt_min_deg,
        home_deg=0.0,
        maximum_deg=args.tilt_max_deg,
        home_pulse_us=args.tilt_home_pulse_us,
        pulse_us_per_degree=args.tilt_pulse_us_per_degree,
        pulse_direction=args.tilt_pulse_direction,
        response_gain_deg_per_second=args.tilt_response_gain,
        max_speed_deg_per_second=args.tilt_max_speed,
        minimum_pulse_us=args.minimum_pulse_us,
        maximum_pulse_us=args.maximum_pulse_us,
    )
    pan.validate()
    tilt.validate()
    return pan, tilt


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Consume local MQTT framing targets and drive two SG90 servos."
    )
    parser.add_argument(
        "--device-id",
        default=os.getenv("DEVICE_ID"),
        help="Device UUID used in the local MQTT topic and payload.",
    )
    parser.add_argument(
        "--mqtt-host",
        default=os.getenv("SERVO_MQTT_HOST", "127.0.0.1"),
    )
    parser.add_argument(
        "--mqtt-port",
        type=int,
        default=int(os.getenv("SERVO_MQTT_PORT", "1883")),
    )
    parser.add_argument("--mqtt-username", default=os.getenv("SERVO_MQTT_USERNAME"))
    parser.add_argument("--mqtt-password", default=os.getenv("SERVO_MQTT_PASSWORD"))
    parser.add_argument("--topic", default=os.getenv("SERVO_TARGET_TOPIC"))
    parser.add_argument("--status-topic", default=os.getenv("SERVO_STATUS_TOPIC"))
    parser.add_argument(
        "--enable-hardware",
        action=argparse.BooleanOptionalAction,
        default=env_bool("SERVO_ENABLE_HARDWARE", False),
        help="Enable PCA9685 writes. Disabled by default.",
    )
    parser.add_argument(
        "--i2c-bus",
        type=int,
        default=(
            int(os.environ["SERVO_I2C_BUS"])
            if os.getenv("SERVO_I2C_BUS")
            else None
        ),
    )
    parser.add_argument(
        "--i2c-address",
        type=parse_int_auto,
        default=parse_int_auto(os.getenv("SERVO_I2C_ADDRESS", "0x40")),
    )
    parser.add_argument(
        "--pwm-frequency",
        type=float,
        default=float(os.getenv("SERVO_PWM_FREQUENCY", "50")),
    )
    parser.add_argument(
        "--oscillator-frequency",
        type=float,
        default=float(os.getenv("PCA9685_OSCILLATOR_HZ", "25000000")),
    )
    parser.add_argument(
        "--pan-channel",
        type=int,
        default=int(os.getenv("SERVO_PAN_CHANNEL", "0")),
    )
    parser.add_argument(
        "--tilt-channel",
        type=int,
        default=int(os.getenv("SERVO_TILT_CHANNEL", "1")),
    )
    parser.add_argument(
        "--pan-min-deg",
        type=float,
        default=float(os.getenv("SERVO_PAN_MIN_DEG", "-80")),
    )
    parser.add_argument(
        "--pan-max-deg",
        type=float,
        default=float(os.getenv("SERVO_PAN_MAX_DEG", "80")),
    )
    parser.add_argument(
        "--tilt-min-deg",
        type=float,
        default=float(os.getenv("SERVO_TILT_MIN_DEG", "-80")),
    )
    parser.add_argument(
        "--tilt-max-deg",
        type=float,
        default=float(os.getenv("SERVO_TILT_MAX_DEG", "80")),
    )
    parser.add_argument(
        "--pan-home-pulse-us",
        type=float,
        default=float(os.getenv("SERVO_PAN_HOME_PULSE_US", "1500")),
    )
    parser.add_argument(
        "--tilt-home-pulse-us",
        type=float,
        default=float(os.getenv("SERVO_TILT_HOME_PULSE_US", "1500")),
    )
    parser.add_argument(
        "--pan-pulse-us-per-degree",
        type=float,
        default=float(os.getenv("SERVO_PAN_PULSE_US_PER_DEGREE", "5.555556")),
    )
    parser.add_argument(
        "--tilt-pulse-us-per-degree",
        type=float,
        default=float(os.getenv("SERVO_TILT_PULSE_US_PER_DEGREE", "5.555556")),
    )
    parser.add_argument(
        "--minimum-pulse-us",
        type=float,
        default=float(os.getenv("SERVO_MINIMUM_PULSE_US", "1000")),
    )
    parser.add_argument(
        "--maximum-pulse-us",
        type=float,
        default=float(os.getenv("SERVO_MAXIMUM_PULSE_US", "2000")),
    )
    parser.add_argument(
        "--pan-pulse-direction",
        type=int,
        choices=(-1, 1),
        default=int(os.getenv("SERVO_PAN_PULSE_DIRECTION", "1")),
    )
    parser.add_argument(
        "--tilt-pulse-direction",
        type=int,
        choices=(-1, 1),
        default=int(os.getenv("SERVO_TILT_PULSE_DIRECTION", "1")),
    )
    parser.add_argument(
        "--pan-response-gain",
        type=float,
        default=float(os.getenv("SERVO_PAN_RESPONSE_GAIN", "45")),
    )
    parser.add_argument(
        "--tilt-response-gain",
        type=float,
        default=float(os.getenv("SERVO_TILT_RESPONSE_GAIN", "45")),
    )
    parser.add_argument(
        "--pan-max-speed",
        type=float,
        default=float(os.getenv("SERVO_PAN_MAX_SPEED", "40")),
    )
    parser.add_argument(
        "--tilt-max-speed",
        type=float,
        default=float(os.getenv("SERVO_TILT_MAX_SPEED", "40")),
    )
    parser.add_argument(
        "--message-timeout",
        type=float,
        default=float(os.getenv("SERVO_MESSAGE_TIMEOUT_SECONDS", "0.75")),
    )
    parser.add_argument(
        "--control-hz",
        type=float,
        default=float(os.getenv("SERVO_CONTROL_HZ", "20")),
    )
    parser.add_argument(
        "--status-interval",
        type=float,
        default=float(os.getenv("SERVO_STATUS_INTERVAL_SECONDS", "0.5")),
    )
    args = parser.parse_args()

    if not args.device_id or not args.device_id.strip():
        parser.error("--device-id or DEVICE_ID is required")
    if not 1 <= args.mqtt_port <= 65_535:
        parser.error("--mqtt-port must be between 1 and 65535")
    if args.enable_hardware and args.i2c_bus is None:
        parser.error("--i2c-bus or SERVO_I2C_BUS is required with hardware enabled")
    if args.control_hz <= 0 or args.status_interval <= 0:
        parser.error("--control-hz and --status-interval must be positive")
    if args.message_timeout <= 0:
        parser.error("--message-timeout must be positive")
    return args


def run(args: argparse.Namespace) -> None:
    try:
        import paho.mqtt.client as mqtt
    except ImportError as exc:
        raise SystemExit(
            "paho-mqtt is missing. Install requirements-servo-controller.txt."
        ) from exc

    pan, tilt = build_axis_configs(args)
    if args.enable_hardware:
        output: ServoOutput = Pca9685ServoOutput(
            i2c_bus=args.i2c_bus,
            address=args.i2c_address,
            frequency_hz=args.pwm_frequency,
            oscillator_hz=args.oscillator_frequency,
            pan=pan,
            tilt=tilt,
        )
    else:
        output = DryRunServoOutput()

    controller = ServoController(
        pan=pan,
        tilt=tilt,
        output=output,
        expected_device_id=args.device_id,
        message_timeout_seconds=args.message_timeout,
    )
    target_topic = args.topic or (
        f"homecam/v2/{args.device_id}/control/framing/target"
    )
    status_topic = args.status_topic or (
        f"homecam/v2/{args.device_id}/control/framing/status"
    )
    connected = threading.Event()
    stop = threading.Event()

    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=f"{args.device_id}-servo-controller",
        protocol=mqtt.MQTTv311,
    )
    if args.mqtt_username:
        client.username_pw_set(args.mqtt_username, args.mqtt_password)

    client.will_set(
        status_topic,
        payload=json.dumps(
            {
                "schema_version": "1.0",
                "device_id": args.device_id,
                "component": "servo_controller",
                "state": "OFFLINE",
                "hardware_enabled": args.enable_hardware,
            },
            separators=(",", ":"),
        ),
        qos=0,
        retain=False,
    )

    def on_connect(
        callback_client: Any,
        userdata: Any,
        connect_flags: Any,
        reason_code: Any,
        properties: Any,
    ) -> None:
        del userdata, connect_flags, properties
        if reason_code.is_failure:
            print(f"MQTT connection rejected: {reason_code}")
            return
        callback_client.subscribe(target_topic, qos=0)
        connected.set()
        print(f"Servo target MQTT: {target_topic}")

    def on_disconnect(
        callback_client: Any,
        userdata: Any,
        disconnect_flags: Any,
        reason_code: Any,
        properties: Any,
    ) -> None:
        del callback_client, userdata, disconnect_flags, properties
        connected.clear()
        if reason_code.is_failure:
            print(f"MQTT disconnected: {reason_code}")

    def on_message(callback_client: Any, userdata: Any, message: Any) -> None:
        del callback_client, userdata
        try:
            decoded = json.loads(message.payload.decode("utf-8"))
            controller.accept_payload(
                decoded,
                received_epoch=time.time(),
                received_monotonic=time.monotonic(),
            )
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            print(f"Rejected framing target: {exc}")

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message

    def request_stop(signum: int, frame: Any) -> None:
        del signum, frame
        stop.set()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    print(
        "Servo hardware: "
        + (
            f"ENABLED (I2C bus {args.i2c_bus}, address {args.i2c_address:#04x})"
            if args.enable_hardware
            else "DISABLED (dry-run)"
        )
    )
    client.connect(args.mqtt_host, args.mqtt_port, keepalive=60)
    client.loop_start()
    last_status_at = float("-inf")
    period = 1.0 / args.control_hz

    try:
        while not stop.wait(period):
            now = time.monotonic()
            controller.tick(now)
            if connected.is_set() and now - last_status_at >= args.status_interval:
                client.publish(
                    status_topic,
                    payload=json.dumps(
                        controller.status_payload(
                            hardware_enabled=args.enable_hardware
                        ),
                        separators=(",", ":"),
                    ),
                    qos=0,
                    retain=False,
                )
                last_status_at = now
    finally:
        controller.close()
        client.disconnect()
        client.loop_stop()


def main() -> None:
    try:
        args = parse_args()
        run(args)
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc


if __name__ == "__main__":
    main()
