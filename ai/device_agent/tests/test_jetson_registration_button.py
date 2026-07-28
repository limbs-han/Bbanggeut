import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from jetson_registration_button import (
    RegistrationDisplay,
    environment_integer,
    parse_args,
    parse_registration_response,
    request_registration_code,
)


class FakeLcd:
    def __init__(self):
        self.lines = []
        self.closed = False

    def write_line(self, row, text, *, width=16):
        self.lines.append((row, text, width))

    def close(self):
        self.closed = True


class FakeResult:
    def __init__(self, returncode=0, stdout=""):
        self.returncode = returncode
        self.stdout = stdout


class JetsonRegistrationButtonTest(unittest.TestCase):
    def test_once_argument_requests_immediate_registration(self):
        self.assertTrue(parse_args(["--once"]).once)
        self.assertFalse(parse_args([]).once)

    def test_display_shows_ready_requesting_and_code(self):
        lcd = FakeLcd()
        display = RegistrationDisplay(lcd, columns=16)

        display.show_ready()
        display.show_requesting()
        display.show_code("ABCD-1234")

        self.assertEqual(
            lcd.lines,
            [
                (0, "Press button", 16),
                (1, "to register", 16),
                (0, "Requesting code", 16),
                (1, "Please wait...", 16),
                (0, "Registration", 16),
                (1, "ABCD-1234", 16),
            ],
        )

    def test_registration_command_requests_json_and_displays_code(self):
        lcd = FakeLcd()
        display = RegistrationDisplay(lcd)
        calls = []

        def runner(command, **kwargs):
            calls.append((command, kwargs))
            return FakeResult(
                stdout=json.dumps(
                    {
                        "registrationCode": "ABCD-1234",
                        "expiresAt": "2026-07-28T08:00:00Z",
                    },
                ),
            )

        command = Path("/opt/device/registration-button.sh")
        result = request_registration_code(
            display,
            command=command,
            timeout=12,
            runner=runner,
        )

        self.assertEqual(result, ("ABCD-1234", "2026-07-28T08:00:00Z"))
        self.assertEqual(calls[0][0], [str(command)])
        self.assertEqual(calls[0][1]["cwd"], command.parent)
        self.assertEqual(calls[0][1]["timeout"], 12)
        self.assertEqual(
            calls[0][1]["env"]["REGISTRATION_CODE_OUTPUT_FORMAT"],
            "json",
        )
        self.assertEqual(lcd.lines[-1], (1, "ABCD-1234", 16))

    def test_registration_command_rejects_failure_and_invalid_json(self):
        display = RegistrationDisplay(FakeLcd())

        with self.assertRaises(RuntimeError):
            request_registration_code(
                display,
                runner=lambda *_args, **_kwargs: FakeResult(returncode=1),
            )
        with self.assertRaises(ValueError):
            parse_registration_response("not-json")
        with self.assertRaises(ValueError):
            parse_registration_response(
                '{"registrationCode":"bad code","expiresAt":"later"}',
            )

    def test_environment_integer_accepts_hex_and_checks_range(self):
        with patch.dict(os.environ, {"LCD_ADDRESS": "0x3f"}):
            self.assertEqual(
                environment_integer("LCD_ADDRESS", 0x27, maximum=0x7F),
                0x3F,
            )
        with patch.dict(os.environ, {"LCD_ADDRESS": "0x80"}):
            with self.assertRaises(ValueError):
                environment_integer("LCD_ADDRESS", 0x27, maximum=0x7F)


if __name__ == "__main__":
    unittest.main()
