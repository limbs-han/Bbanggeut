from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import threading


INSTALL_DIR = Path("/opt/william-james/device-agent")
DEFAULT_GPIO = 17
DEFAULT_TIMEOUT_SECONDS = 30


def positive_integer(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as error:
        raise ValueError(f"{name} must be an integer: {raw}") from error
    if value <= 0:
        raise ValueError(f"{name} must be greater than zero: {value}")
    return value


def main() -> None:
    from gpiozero import Button

    gpio = positive_integer("REGISTRATION_BUTTON_GPIO", DEFAULT_GPIO)
    timeout = positive_integer(
        "REGISTRATION_BUTTON_TIMEOUT_SECONDS",
        DEFAULT_TIMEOUT_SECONDS,
    )
    command = INSTALL_DIR / "registration-button.sh"
    execution_lock = threading.Lock()

    def request_registration_code() -> None:
        if not execution_lock.acquire(blocking=False):
            print("Registration request is already running; ignoring button press.", flush=True)
            return
        try:
            print(f"Registration button pressed on BCM GPIO {gpio}.", flush=True)
            result = subprocess.run(
                [str(command)],
                cwd=INSTALL_DIR,
                check=False,
                timeout=timeout,
            )
            if result.returncode != 0:
                print(
                    f"Registration command failed with exit code {result.returncode}.",
                    flush=True,
                )
        except subprocess.TimeoutExpired:
            print(f"Registration command timed out after {timeout} seconds.", flush=True)
        finally:
            execution_lock.release()

    button = Button(gpio, pull_up=True, bounce_time=0.2)
    button.when_pressed = request_registration_code
    print(
        f"Waiting for registration button on BCM GPIO {gpio} "
        "(wire the button between GPIO and GND).",
        flush=True,
    )
    signal.pause()


if __name__ == "__main__":
    main()
