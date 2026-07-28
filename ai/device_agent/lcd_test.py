"""Test a PCF8574-backed HD44780 LCD on a Jetson Orin Nano."""

from __future__ import annotations

import argparse
import os
import time
from collections.abc import Callable, Sequence
from typing import Protocol


DEFAULT_I2C_BUS = 7
DEFAULT_I2C_ADDRESS = 0x27


class LgpioI2C(Protocol):
    def i2c_open(self, bus: int, address: int, flags: int) -> int: ...

    def i2c_write_byte(self, handle: int, value: int) -> int: ...

    def i2c_close(self, handle: int) -> int: ...


class I2CLcd:
    """Drive the common PCF8574-to-HD44780 backpack pin mapping."""

    RS = 0x01
    ENABLE = 0x04
    BACKLIGHT = 0x08
    ROW_ADDRESSES = (0x80, 0xC0, 0x94, 0xD4)

    def __init__(
        self,
        lgpio_module: LgpioI2C,
        *,
        bus: int = DEFAULT_I2C_BUS,
        address: int = DEFAULT_I2C_ADDRESS,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._lgpio = lgpio_module
        self._sleep = sleep
        self._handle = self._lgpio.i2c_open(bus, address, 0)
        self._backlight = self.BACKLIGHT
        self._closed = False

        try:
            self._initialize()
        except BaseException:
            self.close()
            raise

    def _write_expander(self, value: int) -> None:
        self._lgpio.i2c_write_byte(
            self._handle,
            (value | self._backlight) & 0xFF,
        )

    def _pulse_enable(self, value: int) -> None:
        self._write_expander(value | self.ENABLE)
        self._sleep(0.000001)
        self._write_expander(value & ~self.ENABLE)
        self._sleep(0.00005)

    def _write_nibble(self, nibble: int, mode: int = 0) -> None:
        value = ((nibble & 0x0F) << 4) | mode
        self._write_expander(value)
        self._pulse_enable(value)

    def _send(self, value: int, mode: int = 0) -> None:
        self._write_nibble(value >> 4, mode)
        self._write_nibble(value, mode)

    def command(self, value: int) -> None:
        self._send(value, 0)

    def clear(self) -> None:
        self.command(0x01)
        self._sleep(0.002)

    def set_cursor(self, column: int, row: int) -> None:
        if not 0 <= row < len(self.ROW_ADDRESSES):
            raise ValueError(f"LCD row must be between 0 and 3: {row}")
        if not 0 <= column <= 39:
            raise ValueError(f"LCD column must be between 0 and 39: {column}")
        self.command(self.ROW_ADDRESSES[row] + column)

    def write(self, text: str) -> None:
        # A standard HD44780 character ROM cannot display Korean. Replace any
        # unsupported Unicode character instead of sending an invalid byte.
        for value in text.encode("ascii", errors="replace"):
            self._send(value, self.RS)

    def write_line(self, row: int, text: str, *, width: int = 16) -> None:
        if width <= 0 or width > 40:
            raise ValueError(f"LCD width must be between 1 and 40: {width}")
        self.set_cursor(0, row)
        self.write(text[:width].ljust(width))

    def backlight_off(self) -> None:
        self._backlight = 0
        self._write_expander(0)

    def close(self) -> None:
        if not self._closed:
            self._lgpio.i2c_close(self._handle)
            self._closed = True

    def _initialize(self) -> None:
        self._sleep(0.05)
        self._write_nibble(0x03)
        self._sleep(0.005)
        self._write_nibble(0x03)
        self._sleep(0.0002)
        self._write_nibble(0x03)
        self._write_nibble(0x02)
        self.command(0x28)  # 4-bit mode, two lines, 5x8 font
        self.command(0x0C)  # Display on, cursor and blink off
        self.command(0x06)  # Increment cursor after each character
        self.clear()

    def __enter__(self) -> I2CLcd:
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()


def integer(value: str) -> int:
    """Parse decimal or 0x-prefixed CLI integers."""

    return int(value, 0)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Test an I2C character LCD on a Jetson Orin Nano.",
    )
    parser.add_argument(
        "--bus",
        type=integer,
        default=integer(os.environ.get("LCD_I2C_BUS", str(DEFAULT_I2C_BUS))),
        help="Linux I2C bus number (default: 7)",
    )
    parser.add_argument(
        "--address",
        type=integer,
        default=integer(
            os.environ.get("LCD_I2C_ADDRESS", hex(DEFAULT_I2C_ADDRESS)),
        ),
        help="7-bit I2C address in decimal or 0x-prefixed hex (default: 0x27)",
    )
    parser.add_argument("--columns", type=int, default=16, choices=(16, 20))
    parser.add_argument("--line1", default="Jetson Orin Nano")
    parser.add_argument("--line2", default="lgpio LCD OK")
    parser.add_argument(
        "--hold-seconds",
        type=float,
        default=0,
        help="Keep the process open for this duration after writing",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if args.hold_seconds < 0:
        raise ValueError("--hold-seconds must be zero or greater")

    try:
        import lgpio
    except ImportError as error:
        raise SystemExit(
            "lgpio is not installed. Run: sudo apt install python3-lgpio",
        ) from error

    with I2CLcd(lgpio, bus=args.bus, address=args.address) as lcd:
        lcd.write_line(0, args.line1, width=args.columns)
        lcd.write_line(1, args.line2, width=args.columns)
        if args.hold_seconds:
            time.sleep(args.hold_seconds)

    print(
        f"LCD test text written on /dev/i2c-{args.bus} "
        f"at address 0x{args.address:02X}.",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
