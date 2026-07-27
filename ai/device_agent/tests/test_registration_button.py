import os
import unittest
from unittest.mock import patch

from registration_button import positive_integer


class RegistrationButtonTest(unittest.TestCase):
    def test_positive_integer_uses_default_when_variable_is_missing(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(positive_integer("BUTTON_VALUE", 17), 17)

    def test_positive_integer_rejects_invalid_values(self):
        for value in ("not-a-number", "0", "-1"):
            with self.subTest(value=value):
                with patch.dict(os.environ, {"BUTTON_VALUE": value}):
                    with self.assertRaises(ValueError):
                        positive_integer("BUTTON_VALUE", 17)


if __name__ == "__main__":
    unittest.main()
