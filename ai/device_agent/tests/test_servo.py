import unittest

from servo_test import Pca9685Servo, integer, parse_args


class FakeLgpio:
    def __init__(self):
        self.open_calls = []
        self.reads = []
        self.writes = []
        self.close_calls = []

    def i2c_open(self, bus, address, flags):
        self.open_calls.append((bus, address, flags))
        return 52

    def i2c_read_byte_data(self, handle, register):
        self.reads.append((handle, register))
        return 0x01

    def i2c_write_byte_data(self, handle, register, value):
        self.writes.append((handle, register, value))
        return 0

    def i2c_close(self, handle):
        self.close_calls.append(handle)
        return 0


class Pca9685ServoTest(unittest.TestCase):
    def setUp(self):
        self.lgpio = FakeLgpio()
        self.servo = Pca9685Servo(
            self.lgpio,
            bus=7,
            address=0x40,
            frequency=50,
            sleep=lambda _seconds: None,
        )

    def tearDown(self):
        self.servo.close()

    def test_initializes_50hz_frequency_and_closes_once(self):
        self.assertEqual(self.lgpio.open_calls, [(7, 0x40, 0)])
        self.assertIn((52, self.servo.PRESCALE, 121), self.lgpio.writes)

        self.servo.close()
        self.servo.close()

        self.assertEqual(self.lgpio.close_calls, [52])

    def test_writes_1500_microsecond_pulse_to_channel_zero(self):
        self.lgpio.writes.clear()

        self.servo.set_pulse_us(0, 1500)

        self.assertEqual(
            self.lgpio.writes,
            [
                (52, 0x06, 0),
                (52, 0x07, 0),
                (52, 0x08, 0x33),
                (52, 0x09, 0x01),
            ],
        )

    def test_disables_channel_with_full_off_bit(self):
        self.lgpio.writes.clear()

        self.servo.disable(3)

        self.assertEqual(self.lgpio.writes[-1], (52, 0x15, 0x10))

    def test_rejects_unsafe_values(self):
        with self.assertRaises(ValueError):
            self.servo.set_pulse_us(0, 499)
        with self.assertRaises(ValueError):
            self.servo.set_pulse_us(16, 1500)


class ServoCliTest(unittest.TestCase):
    def test_integer_accepts_hexadecimal(self):
        self.assertEqual(integer("0x40"), 0x40)

    def test_safe_defaults_and_overrides(self):
        defaults = parse_args([])
        custom = parse_args(
            [
                "--bus",
                "1",
                "--address",
                "0x41",
                "--channel",
                "2",
                "--pulses",
                "1300",
                "1700",
            ],
        )

        self.assertEqual(defaults.pulses, (1500, 1200, 1500, 1800, 1500))
        self.assertEqual(
            (custom.bus, custom.address, custom.channel, custom.pulses),
            (1, 0x41, 2, [1300, 1700]),
        )


if __name__ == "__main__":
    unittest.main()
