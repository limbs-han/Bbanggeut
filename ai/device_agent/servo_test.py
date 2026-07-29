"""Safely exercise an SG90 servo through a PCA9685 on a Jetson Orin Nano."""

from __future__ import annotations

import argparse
import time
from collections.abc import Callable, Sequence
from typing import Protocol


DEFAULT_I2C_BUS = 7
DEFAULT_I2C_ADDRESS = 0x40


class LgpioI2C(Protocol):
    def i2c_open(self, bus: int, address: int, flags: int) -> int: ...

    def i2c_read_byte_data(self, handle: int, register: int) -> int: ...

    def i2c_write_byte_data(
        self,
        handle: int,
        register: int,
        value: int,
    ) -> int: ...

    def i2c_close(self, handle: int) -> int: ...


class Pca9685Servo:
    MODE1 = 0x00
    PRESCALE = 0xFE
    LED0_ON_L = 0x06
    RESTART = 0x80
    AUTO_INCREMENT = 0x20
    SLEEP = 0x10
    FULL_OFF = 0x10
    OSCILLATOR_HZ = 25_000_000
    COUNTS = 4096

    def __init__(
        self,
        lgpio_module: LgpioI2C,
        *,
        bus: int = DEFAULT_I2C_BUS,
        address: int = DEFAULT_I2C_ADDRESS,
        frequency: float = 50.0,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        if not 40.0 <= frequency <= 1000.0:
            raise ValueError(
                f"PWM frequency must be between 40 and 1000 Hz: {frequency}",
            )
        self._lgpio = lgpio_module
        self._sleep = sleep
        self._frequency = frequency
        self._handle = self._lgpio.i2c_open(bus, address, 0)
        self._closed = False
        try:
            self._set_frequency(frequency)
        except BaseException:
            self.close()
            raise

    def _read(self, register: int) -> int:
        return self._lgpio.i2c_read_byte_data(self._handle, register)

    def _write(self, register: int, value: int) -> None:
        self._lgpio.i2c_write_byte_data(self._handle, register, value & 0xFF)

    def _set_frequency(self, frequency: float) -> None:
        prescale = round(
            self.OSCILLATOR_HZ / (self.COUNTS * frequency),
        ) - 1
        if not 3 <= prescale <= 255:
            raise ValueError(f"Calculated PCA9685 prescale is invalid: {prescale}")

        old_mode = self._read(self.MODE1)
        sleep_mode = (old_mode & ~self.RESTART) | self.SLEEP
        wake_mode = (
            old_mode
            & ~(self.RESTART | self.SLEEP)
            | self.AUTO_INCREMENT
        )
        self._write(self.MODE1, sleep_mode)
        self._write(self.PRESCALE, prescale)
        self._write(self.MODE1, wake_mode)
        self._sleep(0.005)
        self._write(self.MODE1, wake_mode | self.RESTART)

    @staticmethod
    def _channel_register(channel: int) -> int:
        if not 0 <= channel <= 15:
            raise ValueError(
                f"PCA9685 channel must be between 0 and 15: {channel}",
            )
        return Pca9685Servo.LED0_ON_L + channel * 4

    def set_pulse_us(self, channel: int, pulse_us: int) -> None:
        if not 500 <= pulse_us <= 2500:
            raise ValueError(
                f"Servo pulse must be between 500 and 2500 us: {pulse_us}",
            )
        count = round(pulse_us * self._frequency * self.COUNTS / 1_000_000)
        count = min(max(count, 1), self.COUNTS - 1)
        register = self._channel_register(channel)
        self._write(register, 0)
        self._write(register + 1, 0)
        self._write(register + 2, count & 0xFF)
        self._write(register + 3, (count >> 8) & 0x0F)

    def disable(self, channel: int) -> None:
        register = self._channel_register(channel)
        self._write(register, 0)
        self._write(register + 1, 0)
        self._write(register + 2, 0)
        self._write(register + 3, self.FULL_OFF)

    def close(self) -> None:
        if not self._closed:
            self._lgpio.i2c_close(self._handle)
            self._closed = True

    def __enter__(self) -> Pca9685Servo:
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()


def integer(value: str) -> int:
    return int(value, 0)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Test an SG90 servo through a PCA9685 on Jetson.",
    )
    parser.add_argument("--bus", type=integer, default=DEFAULT_I2C_BUS)
    parser.add_argument("--address", type=integer, default=DEFAULT_I2C_ADDRESS)
    parser.add_argument("--channel", type=int, default=0)
    parser.add_argument("--frequency", type=float, default=50.0)
    parser.add_argument(
        "--pulses",
        type=integer,
        nargs="+",
        default=(1500, 1200, 1500, 1800, 1500),
        help="Safe test pulse sequence in microseconds",
    )
    parser.add_argument("--hold-seconds", type=float, default=1.0)
    parser.add_argument(
        "--keep-powered",
        action="store_true",
        help="Keep the last PWM pulse active when the test finishes",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if not 0 <= args.channel <= 15:
        raise ValueError("--channel must be between 0 and 15")
    if args.hold_seconds < 0:
        raise ValueError("--hold-seconds must be zero or greater")
    for pulse in args.pulses:
        if not 500 <= pulse <= 2500:
            raise ValueError("--pulses values must be between 500 and 2500 us")

    try:
        import lgpio
    except ImportError as error:
        raise SystemExit(
            "lgpio is not installed. Run: sudo apt install python3-lgpio",
        ) from error

    with Pca9685Servo(
        lgpio,
        bus=args.bus,
        address=args.address,
        frequency=args.frequency,
    ) as servo:
        try:
            for pulse in args.pulses:
                print(f"channel={args.channel} pulse={pulse}us", flush=True)
                servo.set_pulse_us(args.channel, pulse)
                time.sleep(args.hold_seconds)
        finally:
            if not args.keep_powered:
                servo.disable(args.channel)

    print("Servo test completed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
