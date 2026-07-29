import unittest

from lcd_test import I2CLcd, integer, parse_args


class FakeLgpio:
    def __init__(self):
        self.open_calls = []
        self.writes = []
        self.close_calls = []

    def i2c_open(self, bus, address, flags):
        self.open_calls.append((bus, address, flags))
        return 41

    def i2c_write_byte(self, handle, value):
        self.writes.append((handle, value))
        return 0

    def i2c_close(self, handle):
        self.close_calls.append(handle)
        return 0


class I2CLcdTest(unittest.TestCase):
    def setUp(self):
        self.lgpio = FakeLgpio()
        self.lcd = I2CLcd(
            self.lgpio,
            bus=7,
            address=0x27,
            sleep=lambda _seconds: None,
        )
        self.lgpio.writes.clear()

    def tearDown(self):
        self.lcd.close()

    def test_opens_jetson_i2c_bus_and_closes_once(self):
        self.assertEqual(self.lgpio.open_calls, [(7, 0x27, 0)])

        self.lcd.close()
        self.lcd.close()

        self.assertEqual(self.lgpio.close_calls, [41])

    def test_write_line_replaces_non_ascii_and_pads_to_width(self):
        sent_values = []
        self.lcd.set_cursor = lambda column, row: None
        self.lcd._send = lambda value, mode=0: sent_values.append((value, mode))

        self.lcd.write_line(0, "LCD 한글", width=8)

        expected = b"LCD ??  "
        self.assertEqual(
            sent_values,
            [(value, self.lcd.RS) for value in expected],
        )

    def test_rejects_invalid_cursor_and_width(self):
        with self.assertRaises(ValueError):
            self.lcd.set_cursor(0, 4)
        with self.assertRaises(ValueError):
            self.lcd.set_cursor(40, 0)
        with self.assertRaises(ValueError):
            self.lcd.write_line(0, "test", width=0)

    def test_backlight_off_writes_without_backlight_bit(self):
        self.lcd.backlight_off()

        self.assertEqual(self.lgpio.writes[-1], (41, 0))


class CliTest(unittest.TestCase):
    def test_integer_accepts_hexadecimal(self):
        self.assertEqual(integer("0x3f"), 0x3F)

    def test_jetson_defaults_and_overrides(self):
        defaults = parse_args([])
        custom = parse_args(["--bus", "1", "--address", "0x3f", "--columns", "20"])

        self.assertEqual((defaults.bus, defaults.address), (7, 0x27))
        self.assertEqual((custom.bus, custom.address, custom.columns), (1, 0x3F, 20))


if __name__ == "__main__":
    unittest.main()
