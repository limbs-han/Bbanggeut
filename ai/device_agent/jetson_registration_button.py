"""Show a newly issued registration code on an I2C LCD after a button press."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time
from collections.abc import Callable
from typing import Any, Protocol


INSTALL_DIR = Path("/opt/william-james/device-agent")
DEFAULT_GPIO_CHIP = 0
DEFAULT_GPIO_LINE = 144
DEFAULT_I2C_BUS = 7
DEFAULT_I2C_ADDRESS = 0x27
DEFAULT_COLUMNS = 16
DEFAULT_TIMEOUT_SECONDS = 30
DEFAULT_DEBOUNCE_SECONDS = 0.3
DEFAULT_FAILURE_REASON_SECONDS = 3
DEFAULT_FAILURE_READY_SECONDS = 5

# provision.py reports a rejected request as "... (<status>, <ERROR_CODE>)" on
# stderr. The exit code is always 1, so stderr is the only way to tell an
# already-claimed device apart from a bad token or an unreachable server.
FAILURE_STATUS_PATTERN = re.compile(r"\((\d{3}),\s*([A-Za-z_][A-Za-z0-9_]*)\)")

ALREADY_REGISTERED_CODE = "DEVICE_ALREADY_CLAIMED"
ALREADY_REGISTERED_STATUS = 409

# Lines are ASCII and at most 16 characters: the LCD replaces anything else and
# truncates to the configured column count.
ALREADY_REGISTERED_LINES = ("Device already", "registered")
TEMPORARY_FAILURE_LINES = ("Temporary error", "Try again later")


class RegistrationFailure(RuntimeError):
    """A failed registration attempt carrying the two lines to display."""

    def __init__(
        self,
        lines: tuple[str, str],
        *,
        message: str | None = None,
    ) -> None:
        super().__init__(message or " ".join(lines))
        self.lines = lines


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Issue a registration code and show it on an I2C LCD.",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="issue and display one code immediately without waiting for a button",
    )
    return parser.parse_args(argv)


class Lcd(Protocol):
    def write_line(self, row: int, text: str, *, width: int = 16) -> None: ...

    def close(self) -> None: ...


class RegistrationDisplay:
    def __init__(self, lcd: Lcd, *, columns: int = DEFAULT_COLUMNS) -> None:
        if columns not in (16, 20):
            raise ValueError(f"LCD columns must be 16 or 20: {columns}")
        self._lcd = lcd
        self._columns = columns
        self._lock = threading.Lock()

    def _show(self, line1: str, line2: str) -> None:
        with self._lock:
            self._lcd.write_line(0, line1, width=self._columns)
            self._lcd.write_line(1, line2, width=self._columns)

    def show_ready(self) -> None:
        self._show("Press button", "to register")

    def show_requesting(self) -> None:
        self._show("Requesting code", "Please wait...")

    def show_code(self, code: str) -> None:
        self._show("Registration", code)

    def show_expired(self) -> None:
        self._show("Code expired", "Press button")

    def show_failed(self) -> None:
        self._show("Registration", "Failed")

    def show_reason(self, line1: str, line2: str) -> None:
        self._show(line1, line2)

    def close(self) -> None:
        self._lcd.close()


def environment_integer(
    name: str,
    default: int,
    *,
    minimum: int = 0,
    maximum: int | None = None,
) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw, 0)
    except ValueError as error:
        raise ValueError(f"{name} must be an integer: {raw}") from error
    if value < minimum or (maximum is not None and value > maximum):
        limit = f"{minimum}..{maximum}" if maximum is not None else f">={minimum}"
        raise ValueError(f"{name} must be in {limit}: {value}")
    return value


def seconds_until_expiry(
    expires_at: str,
    *,
    now: datetime | None = None,
) -> float:
    normalized = (
        f"{expires_at[:-1]}+00:00"
        if expires_at.endswith(("Z", "z"))
        else expires_at
    )
    try:
        expiry = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise ValueError(f"Invalid registration expiry: {expires_at}") from error
    if expiry.tzinfo is None:
        raise ValueError("Registration expiry must include a timezone")
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        raise ValueError("Current time must include a timezone")
    return max((expiry - current).total_seconds(), 0.0)


class CodeExpiryTimer:
    def __init__(
        self,
        display: RegistrationDisplay,
        *,
        timer_factory: Callable[..., Any] = threading.Timer,
    ) -> None:
        self._display = display
        self._timer_factory = timer_factory
        self._lock = threading.Lock()
        self._timer: Any | None = None
        self._generation = 0

    def schedule(self, expires_at: str) -> None:
        delay = seconds_until_expiry(expires_at)
        with self._lock:
            self._generation += 1
            generation = self._generation
            if self._timer is not None:
                self._timer.cancel()
            timer = self._timer_factory(
                delay,
                self._expire,
                args=(generation,),
            )
            timer.daemon = True
            self._timer = timer
            timer.start()

    def cancel(self) -> None:
        with self._lock:
            self._generation += 1
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None

    def _expire(self, generation: int) -> None:
        with self._lock:
            if generation != self._generation:
                return
            self._timer = None
        self._display.show_expired()


class FailureNotice:
    """Show the failure, then why it failed, then return to the ready screen.

    Both steps run on timers so the button stays responsive: a new press
    cancels the pending steps instead of letting a stale one overwrite the
    fresh code.
    """

    def __init__(
        self,
        display: RegistrationDisplay,
        *,
        reason_delay: float = DEFAULT_FAILURE_REASON_SECONDS,
        ready_delay: float = DEFAULT_FAILURE_READY_SECONDS,
        timer_factory: Callable[..., Any] = threading.Timer,
    ) -> None:
        self._display = display
        self._reason_delay = reason_delay
        self._ready_delay = ready_delay
        self._timer_factory = timer_factory
        self._lock = threading.Lock()
        self._timers: list[Any] = []
        self._generation = 0

    def start(self, line1: str, line2: str) -> None:
        self._display.show_failed()
        steps = (
            (self._reason_delay, self._display.show_reason, (line1, line2)),
            (self._reason_delay + self._ready_delay, self._display.show_ready, ()),
        )
        with self._lock:
            self._generation += 1
            generation = self._generation
            self._cancel_timers()
            for delay, action, action_args in steps:
                timer = self._timer_factory(
                    delay,
                    self._run,
                    args=(generation, action, action_args),
                )
                timer.daemon = True
                self._timers.append(timer)
                timer.start()

    def cancel(self) -> None:
        with self._lock:
            self._generation += 1
            self._cancel_timers()

    def _cancel_timers(self) -> None:
        for timer in self._timers:
            timer.cancel()
        self._timers = []

    def _run(
        self,
        generation: int,
        action: Callable[..., None],
        action_args: tuple[Any, ...],
    ) -> None:
        with self._lock:
            if generation != self._generation:
                return
        action(*action_args)


def wait_until_expired(
    display: RegistrationDisplay,
    expires_at: str,
    *,
    sleep: Callable[[float], None] = time.sleep,
) -> None:
    sleep(seconds_until_expiry(expires_at))
    display.show_expired()


def parse_registration_response(output: str) -> tuple[str, str]:
    try:
        value = json.loads(output)
    except json.JSONDecodeError as error:
        raise ValueError("Registration command did not return JSON") from error
    if not isinstance(value, dict):
        raise ValueError("Registration response must be an object")
    code = value.get("registrationCode")
    expires_at = value.get("expiresAt")
    if (
        not isinstance(code, str)
        or not code
        or not code.isascii()
        or any(character.isspace() for character in code)
    ):
        raise ValueError("Registration response has an invalid code")
    if not isinstance(expires_at, str) or not expires_at:
        raise ValueError("Registration response has an invalid expiry")
    return code, expires_at


def last_error_line(stderr: str | None) -> str:
    lines = [line.strip() for line in (stderr or "").splitlines() if line.strip()]
    return lines[-1] if lines else "no stderr output"


def describe_failure(stderr: str | None) -> tuple[str, str]:
    """Summarise a failed registration command as two LCD lines.

    Only an already-registered device gets a specific message, because it is
    the one cause the person at the device can act on. Every other cause - a
    rejected token, a server fault, an unreachable network - stays generic so
    the LCD never exposes why the request was refused. The journal keeps the
    real reason for whoever is debugging the device.
    """
    for raw_status, code in FAILURE_STATUS_PATTERN.findall(stderr or ""):
        if code == ALREADY_REGISTERED_CODE or int(raw_status) == ALREADY_REGISTERED_STATUS:
            return ALREADY_REGISTERED_LINES
    return TEMPORARY_FAILURE_LINES


def request_registration_code(
    display: RegistrationDisplay,
    *,
    command: Path = INSTALL_DIR / "registration-button.sh",
    timeout: int = DEFAULT_TIMEOUT_SECONDS,
    runner: Callable[..., Any] = subprocess.run,
) -> tuple[str, str]:
    display.show_requesting()
    environment = os.environ.copy()
    environment["REGISTRATION_CODE_OUTPUT_FORMAT"] = "json"
    result = runner(
        [str(command)],
        cwd=command.parent,
        check=False,
        timeout=timeout,
        capture_output=True,
        text=True,
        env=environment,
    )
    if result.returncode != 0:
        raise RegistrationFailure(
            describe_failure(result.stderr),
            message=(
                f"Registration command failed with exit code "
                f"{result.returncode}: {last_error_line(result.stderr)}"
            ),
        )
    code, expires_at = parse_registration_response(result.stdout)
    display.show_code(code)
    return code, expires_at


def main(argv: list[str] | None = None) -> None:
    import lgpio

    from lcd_test import I2CLcd

    args = parse_args(argv)
    chip = environment_integer("REGISTRATION_BUTTON_CHIP", DEFAULT_GPIO_CHIP)
    line = environment_integer("REGISTRATION_BUTTON_LINE", DEFAULT_GPIO_LINE)
    bus = environment_integer("LCD_I2C_BUS", DEFAULT_I2C_BUS)
    address = environment_integer(
        "LCD_I2C_ADDRESS",
        DEFAULT_I2C_ADDRESS,
        maximum=0x7F,
    )
    columns = environment_integer(
        "LCD_COLUMNS",
        DEFAULT_COLUMNS,
        minimum=16,
        maximum=20,
    )
    if columns not in (16, 20):
        raise ValueError(f"LCD_COLUMNS must be 16 or 20: {columns}")
    timeout = environment_integer(
        "REGISTRATION_BUTTON_TIMEOUT_SECONDS",
        DEFAULT_TIMEOUT_SECONDS,
        minimum=1,
    )
    reason_delay = environment_integer(
        "REGISTRATION_FAILURE_REASON_SECONDS",
        DEFAULT_FAILURE_REASON_SECONDS,
        minimum=1,
    )
    ready_delay = environment_integer(
        "REGISTRATION_FAILURE_READY_SECONDS",
        DEFAULT_FAILURE_READY_SECONDS,
        minimum=1,
    )

    lcd = I2CLcd(lgpio, bus=bus, address=address)
    display = RegistrationDisplay(lcd, columns=columns)

    if args.once:
        try:
            code, expires_at = request_registration_code(display, timeout=timeout)
            print(
                f"Registration code issued: {code}; expires at {expires_at}",
                flush=True,
            )
            wait_until_expired(display, expires_at)
            print("Registration code expired.", flush=True)
        except subprocess.TimeoutExpired:
            display.show_reason(*TEMPORARY_FAILURE_LINES)
            print(
                f"Registration command timed out after {timeout} seconds.",
                flush=True,
            )
            raise SystemExit(1)
        except RegistrationFailure as error:
            display.show_reason(*error.lines)
            print(f"Registration request failed: {error}", flush=True)
            raise SystemExit(1)
        except Exception as error:
            display.show_reason(*TEMPORARY_FAILURE_LINES)
            print(f"Registration request failed: {error}", flush=True)
            raise SystemExit(1)
        finally:
            display.close()
        return

    execution_lock = threading.Lock()
    debounce_lock = threading.Lock()
    expiry_timer = CodeExpiryTimer(display)
    failure_notice = FailureNotice(
        display,
        reason_delay=reason_delay,
        ready_delay=ready_delay,
    )
    last_press = 0.0

    def run_request() -> None:
        if not execution_lock.acquire(blocking=False):
            print("Registration request is already running; ignoring press.", flush=True)
            return
        try:
            expiry_timer.cancel()
            failure_notice.cancel()
            code, expires_at = request_registration_code(display, timeout=timeout)
            expiry_timer.schedule(expires_at)
            print(
                f"Registration code issued: {code}; expires at {expires_at}",
                flush=True,
            )
        except subprocess.TimeoutExpired:
            print(f"Registration command timed out after {timeout} seconds.", flush=True)
            failure_notice.start(*TEMPORARY_FAILURE_LINES)
        except RegistrationFailure as error:
            print(f"Registration request failed: {error}", flush=True)
            failure_notice.start(*error.lines)
        except Exception as error:
            print(f"Registration request failed: {error}", flush=True)
            failure_notice.start(*TEMPORARY_FAILURE_LINES)
        finally:
            execution_lock.release()

    def on_button_edge(
        _chip: int,
        _line: int,
        level: int,
        _timestamp: int,
    ) -> None:
        nonlocal last_press
        if level != 0:
            return
        now = time.monotonic()
        with debounce_lock:
            if now - last_press < DEFAULT_DEBOUNCE_SECONDS:
                return
            last_press = now
        threading.Thread(target=run_request, daemon=True).start()

    gpio_handle = lgpio.gpiochip_open(chip)
    callback = None
    try:
        lgpio.gpio_claim_alert(gpio_handle, line, lgpio.FALLING_EDGE)
        callback = lgpio.callback(
            gpio_handle,
            line,
            lgpio.FALLING_EDGE,
            on_button_edge,
        )
        display.show_ready()
        print(
            f"Waiting for Jetson registration button on gpiochip{chip} "
            f"line {line}; LCD is /dev/i2c-{bus} at 0x{address:02X}.",
            flush=True,
        )
        signal.pause()
    finally:
        expiry_timer.cancel()
        failure_notice.cancel()
        if callback is not None:
            callback.cancel()
        try:
            lgpio.gpio_free(gpio_handle, line)
        finally:
            lgpio.gpiochip_close(gpio_handle)
            display.close()


if __name__ == "__main__":
    main()
