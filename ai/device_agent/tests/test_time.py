from datetime import datetime, timezone
import sys
import types
import unittest

# Time parsing is independent of MQTT. Keep this unit test runnable without
# installing the runtime-only paho dependency on the development machine.
sys.modules.setdefault("paho", types.ModuleType("paho"))
sys.modules.setdefault("paho.mqtt", types.ModuleType("paho.mqtt"))
sys.modules.setdefault("paho.mqtt.client", types.ModuleType("paho.mqtt.client"))

from wj_device_agent.agent import parse_time


class ParseTimeTest(unittest.TestCase):
    def test_accepts_java_instant_nanoseconds(self):
        self.assertEqual(
            parse_time("2026-07-22T14:30:51.145813425Z"),
            datetime(2026, 7, 22, 14, 30, 51, 145813, tzinfo=timezone.utc),
        )

    def test_preserves_supported_microseconds_and_offsets(self):
        self.assertEqual(
            parse_time("2026-07-22T23:30:51.123456+09:00"),
            datetime(2026, 7, 22, 14, 30, 51, 123456, tzinfo=timezone.utc),
        )


if __name__ == "__main__":
    unittest.main()
