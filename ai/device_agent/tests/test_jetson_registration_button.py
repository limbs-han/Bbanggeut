import json
import os
from datetime import datetime, timezone
from pathlib import Path
import unittest
from unittest.mock import patch

from jetson_registration_button import (
    ALREADY_REGISTERED_LINES,
    CodeExpiryTimer,
    FailureNotice,
    RegistrationDisplay,
    RegistrationFailure,
    TEMPORARY_FAILURE_LINES,
    describe_failure,
    environment_integer,
    last_error_line,
    normalize_expiry,
    parse_args,
    parse_registration_response,
    request_registration_code,
    seconds_until_expiry,
    wait_until_expired,
)


REJECTED_STDERR = (
    "Traceback (most recent call last):\n"
    "urllib.error.HTTPError: HTTP Error 409: \n"
    "RuntimeError: 서버가 요청을 거부했습니다 (409, DEVICE_ALREADY_CLAIMED)\n"
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
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class FakeTimer:
    instances = []

    def __init__(self, delay, callback, args=()):
        self.delay = delay
        self.callback = callback
        self.args = args
        self.daemon = False
        self.started = False
        self.cancelled = False
        self.__class__.instances.append(self)

    def start(self):
        self.started = True

    def cancel(self):
        self.cancelled = True

    def fire(self):
        self.callback(*self.args)


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
        display.show_expired()

        self.assertEqual(
            lcd.lines,
            [
                (0, "Press button", 16),
                (1, "to register", 16),
                (0, "Requesting code", 16),
                (1, "Please wait...", 16),
                (0, "Registration", 16),
                (1, "ABCD-1234", 16),
                (0, "Code expired", 16),
                (1, "Press button", 16),
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

    def test_expiry_delay_uses_server_timestamp_and_never_goes_negative(self):
        now = datetime(2026, 7, 29, 6, 0, 0, tzinfo=timezone.utc)

        self.assertAlmostEqual(
            seconds_until_expiry(
                "2026-07-29T06:02:00.123456789Z",
                now=now,
            ),
            120.123456,
        )
        self.assertEqual(
            seconds_until_expiry("2026-07-29T05:59:00Z", now=now),
            0.0,
        )
        with self.assertRaises(ValueError):
            seconds_until_expiry("2026-07-29T06:02:00", now=now)

    def test_expiry_accepts_every_fractional_precision_the_server_sends(self):
        now = datetime(2026, 7, 29, 6, 0, 0, tzinfo=timezone.utc)

        # ISO_INSTANT emits 0, 3, 6, or 9 digits; 3.10 accepts only 0, 3, 6.
        for digits, expected in (
            ("", 120.0),
            (".5", 120.5),
            (".123", 120.123),
            (".123456", 120.123456),
            (".123456789", 120.123456),
        ):
            with self.subTest(digits=digits):
                self.assertAlmostEqual(
                    seconds_until_expiry(f"2026-07-29T06:02:00{digits}Z", now=now),
                    expected,
                )

    def test_expiry_normalisation_keeps_the_offset_intact(self):
        self.assertEqual(
            normalize_expiry("2026-07-29T06:02:00.123456789Z"),
            "2026-07-29T06:02:00.123456+00:00",
        )
        self.assertEqual(
            normalize_expiry("2026-07-29T06:02:00.5+09:00"),
            "2026-07-29T06:02:00.500000+09:00",
        )
        self.assertEqual(
            normalize_expiry("2026-07-29T06:02:00+09:00"),
            "2026-07-29T06:02:00+09:00",
        )

    @patch(
        "jetson_registration_button.seconds_until_expiry",
        side_effect=[120.0, 180.0],
    )
    def test_expiry_timer_replaces_old_timer_and_shows_expired(
        self,
        expiry_delay,
    ):
        FakeTimer.instances = []
        lcd = FakeLcd()
        timer = CodeExpiryTimer(
            RegistrationDisplay(lcd),
            timer_factory=FakeTimer,
        )

        timer.schedule("2026-07-29T06:02:00Z")
        first = FakeTimer.instances[-1]
        timer.schedule("2026-07-29T06:03:00Z")
        second = FakeTimer.instances[-1]

        self.assertTrue(first.cancelled)
        self.assertTrue(second.started)
        self.assertTrue(second.daemon)
        self.assertEqual(second.delay, 180.0)
        self.assertEqual(expiry_delay.call_count, 2)
        first.fire()
        self.assertEqual(lcd.lines, [])
        second.fire()
        self.assertEqual(
            lcd.lines,
            [
                (0, "Code expired", 16),
                (1, "Press button", 16),
            ],
        )

    def test_once_waits_until_expiry_then_updates_display(self):
        lcd = FakeLcd()
        display = RegistrationDisplay(lcd)
        delays = []
        now = datetime.now(timezone.utc)
        expires_at = now.isoformat()

        wait_until_expired(display, expires_at, sleep=delays.append)

        self.assertEqual(delays, [0.0])
        self.assertEqual(lcd.lines[-2:], [
            (0, "Code expired", 16),
            (1, "Press button", 16),
        ])

    def test_already_registered_device_is_named_on_the_lcd(self):
        self.assertEqual(describe_failure(REJECTED_STDERR), ALREADY_REGISTERED_LINES)
        # The status alone is enough when a future error code is used.
        self.assertEqual(
            describe_failure("RuntimeError: ... (409, SOMETHING_NEW)"),
            ALREADY_REGISTERED_LINES,
        )
        self.assertEqual(ALREADY_REGISTERED_LINES, ("Device already", "registered"))

    def test_every_other_failure_stays_generic_on_the_lcd(self):
        for stderr in (
            "RuntimeError: ... (401, DEVICE_AUTHENTICATION_FAILED)",
            "RuntimeError: ... (403, ACCESS_DENIED)",
            "RuntimeError: ... (404, NOT_FOUND)",
            "RuntimeError: ... (429, TOO_MANY_REQUESTS)",
            "RuntimeError: ... (500, INTERNAL_SERVER_ERROR)",
            "RuntimeError: ... (418, HTTP_ERROR)",
            "urllib.error.URLError: <urlopen error unreachable>",
            "ValueError: env에 DEVICE_BEARER_TOKEN이 없습니다",
            "Device environment is not readable: /etc/x.env",
            "",
            None,
        ):
            self.assertEqual(describe_failure(stderr), TEMPORARY_FAILURE_LINES, stderr)

    def test_lcd_never_leaks_the_status_or_error_code(self):
        leaky = (
            "RuntimeError: 서버가 요청을 거부했습니다 (401, DEVICE_AUTHENTICATION_FAILED)"
        )
        lines = describe_failure(leaky)

        shown = " ".join(lines)
        self.assertNotIn("401", shown)
        self.assertNotIn("DEVICE_AUTHENTICATION_FAILED", shown)
        self.assertNotIn("Auth", shown)

    def test_failure_lines_fit_the_lcd(self):
        for lines in (ALREADY_REGISTERED_LINES, TEMPORARY_FAILURE_LINES):
            for line in lines:
                self.assertTrue(line.isascii(), line)
                self.assertLessEqual(len(line), 16, line)

    def test_last_error_line_reports_the_final_message(self):
        self.assertEqual(
            last_error_line(REJECTED_STDERR),
            "RuntimeError: 서버가 요청을 거부했습니다 (409, DEVICE_ALREADY_CLAIMED)",
        )
        self.assertEqual(last_error_line(""), "no stderr output")
        self.assertEqual(last_error_line(None), "no stderr output")

    def test_registration_command_reports_the_rejection_reason(self):
        display = RegistrationDisplay(FakeLcd())

        with self.assertRaises(RegistrationFailure) as raised:
            request_registration_code(
                display,
                runner=lambda *_args, **_kwargs: FakeResult(
                    returncode=1,
                    stderr=REJECTED_STDERR,
                ),
            )

        self.assertEqual(raised.exception.lines, ALREADY_REGISTERED_LINES)
        # The log keeps the reason the LCD deliberately does not show.
        self.assertIn("exit code 1", str(raised.exception))
        self.assertIn("DEVICE_ALREADY_CLAIMED", str(raised.exception))

    def test_rejected_token_is_logged_but_not_displayed(self):
        display = RegistrationDisplay(FakeLcd())
        stderr = "RuntimeError: 서버가 요청을 거부했습니다 (401, DEVICE_AUTHENTICATION_FAILED)"

        with self.assertRaises(RegistrationFailure) as raised:
            request_registration_code(
                display,
                runner=lambda *_args, **_kwargs: FakeResult(returncode=1, stderr=stderr),
            )

        self.assertEqual(raised.exception.lines, TEMPORARY_FAILURE_LINES)
        self.assertIn("DEVICE_AUTHENTICATION_FAILED", str(raised.exception))

    def test_failure_notice_shows_failed_then_reason_then_ready(self):
        FakeTimer.instances = []
        lcd = FakeLcd()
        notice = FailureNotice(
            RegistrationDisplay(lcd),
            reason_delay=3,
            ready_delay=5,
            timer_factory=FakeTimer,
        )

        notice.start(*ALREADY_REGISTERED_LINES)

        self.assertEqual(
            lcd.lines,
            [(0, "Registration", 16), (1, "Failed", 16)],
        )
        reason_timer, ready_timer = FakeTimer.instances
        self.assertEqual(reason_timer.delay, 3)
        self.assertEqual(ready_timer.delay, 8)
        self.assertTrue(reason_timer.started)
        self.assertTrue(ready_timer.started)
        self.assertTrue(reason_timer.daemon)
        self.assertTrue(ready_timer.daemon)

        reason_timer.fire()
        self.assertEqual(
            lcd.lines[-2:],
            [(0, "Device already", 16), (1, "registered", 16)],
        )
        ready_timer.fire()
        self.assertEqual(
            lcd.lines[-2:],
            [(0, "Press button", 16), (1, "to register", 16)],
        )

    def test_failure_notice_drops_stale_steps_after_a_new_press(self):
        FakeTimer.instances = []
        lcd = FakeLcd()
        notice = FailureNotice(RegistrationDisplay(lcd), timer_factory=FakeTimer)

        notice.start(*TEMPORARY_FAILURE_LINES)
        stale_reason, stale_ready = FakeTimer.instances
        notice.cancel()
        lcd.lines.clear()

        stale_reason.fire()
        stale_ready.fire()

        self.assertTrue(stale_reason.cancelled)
        self.assertTrue(stale_ready.cancelled)
        # A stale step must never overwrite the code from a fresh press.
        self.assertEqual(lcd.lines, [])

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
