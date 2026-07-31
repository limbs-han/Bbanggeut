from __future__ import annotations

import json
import unittest

from mqtt_event_publisher import MqttEventPublisher


class FakeMessage:
    def wait_for_publish(self, timeout: float) -> None:
        self.timeout = timeout

    def is_published(self) -> bool:
        return True


class FakeClient:
    def publish(
        self,
        topic: str,
        *,
        payload: str,
        qos: int,
        retain: bool,
    ) -> FakeMessage:
        self.topic = topic
        self.payload = payload
        self.qos = qos
        self.retain = retain
        return FakeMessage()


class MqttEventPublisherTests(unittest.TestCase):
    def test_local_trigger_id_is_reused_for_mqtt_detection(self) -> None:
        publisher = MqttEventPublisher.__new__(MqttEventPublisher)
        publisher._device_id = "device-1"
        publisher._custom_event_topic = None
        publisher._client = FakeClient()

        event_id = publisher.publish_laughter(
            event_id="local-trigger-1",
            score=0.81,
            class_name="Laughter",
            threshold=0.125,
            consecutive=3,
            monotonic_ns=123,
        )
        payload = json.loads(publisher._client.payload)

        self.assertEqual(event_id, "local-trigger-1")
        self.assertEqual(payload["event_id"], "local-trigger-1")
        self.assertEqual(payload["score"], 0.81)
        self.assertEqual(payload["event_type"], "laughter")
        self.assertEqual(
            publisher._client.topic,
            "homecam/v2/device-1/ai/laughter/detected",
        )
        self.assertEqual(publisher._client.qos, 1)

    def test_generic_clap_event_uses_type_specific_topic(self) -> None:
        publisher = MqttEventPublisher.__new__(MqttEventPublisher)
        publisher._device_id = "device-1"
        publisher._custom_event_topic = None
        publisher._client = FakeClient()

        event_id = publisher.publish_event(
            event_type="CLAP",
            event_id="clap-1",
            score=0.72,
            class_name="Clapping",
            threshold=0.3,
            consecutive=3,
            monotonic_ns=456,
            metadata={"activeSeconds": 1.1},
        )
        payload = json.loads(publisher._client.payload)

        self.assertEqual(event_id, "clap-1")
        self.assertEqual(payload["event_type"], "clap")
        self.assertEqual(payload["metadata"]["activeSeconds"], 1.1)
        self.assertEqual(
            publisher._client.topic,
            "homecam/v2/device-1/ai/clap/detected",
        )


if __name__ == "__main__":
    unittest.main()
