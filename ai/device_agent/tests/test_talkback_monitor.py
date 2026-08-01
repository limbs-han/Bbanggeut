from datetime import datetime, timedelta, timezone
import unittest
from unittest.mock import patch

from wj_device_agent.agent import DeviceAgent
from wj_device_agent.talkback import TalkbackSnapshot


STREAM_ID = "22222222-2222-4222-8222-222222222222"
NOW = datetime(2026, 8, 1, 12, 0, tzinfo=timezone.utc)


class FakeTalkback:
    """플레이어 수명주기만 흉내 내는 대역."""

    def __init__(self, finished: TalkbackSnapshot | None) -> None:
        self._finished = finished
        self.started: list[tuple[str, datetime]] = []
        self.stopped: list[str | None] = []
        self.running_snapshot = TalkbackSnapshot(None, False, None, None)

    def snapshot(self) -> TalkbackSnapshot:
        return self.running_snapshot

    def clear_if_finished(self) -> TalkbackSnapshot | None:
        value = self._finished
        self._finished = None
        return value

    def start(self, stream_id: str, hard_expires_at: datetime) -> bool:
        self.started.append((stream_id, hard_expires_at))
        return True

    def stop(self, stream_id: str | None = None) -> bool:
        self.stopped.append(stream_id)
        return True


def agent_with(talkback: FakeTalkback) -> DeviceAgent:
    agent = DeviceAgent.__new__(DeviceAgent)
    agent.talkback = talkback
    agent.talkback_retries = 0
    return agent


class TalkbackMonitorTest(unittest.TestCase):
    def test_player_is_restarted_while_the_speaking_lease_is_alive(self):
        # 서버는 whipUrl을 앱에 주기 전에 START_TALKBACK을 보낸다. 기기가 먼저
        # 읽으러 가면 경로가 없어 플레이어가 즉시 끝나는데, 여기서 포기하면
        # 1~2초 뒤 시작된 발화를 아무도 듣지 못한다.
        lease_end = NOW + timedelta(seconds=25)
        talkback = FakeTalkback(TalkbackSnapshot(STREAM_ID, False, lease_end, 0))
        agent = agent_with(talkback)

        with patch("wj_device_agent.agent.utc_now", return_value=NOW):
            agent._monitor_talkback()

        self.assertEqual(talkback.started, [(STREAM_ID, lease_end)])
        self.assertEqual(agent.talkback_retries, 1)

    def test_player_is_not_restarted_after_the_lease_expires(self):
        lease_end = NOW - timedelta(seconds=1)
        talkback = FakeTalkback(TalkbackSnapshot(STREAM_ID, False, lease_end, 0))
        agent = agent_with(talkback)

        with patch("wj_device_agent.agent.utc_now", return_value=NOW):
            agent._monitor_talkback()

        self.assertEqual(talkback.started, [])
        self.assertEqual(agent.talkback_retries, 0)

    def test_expired_lease_closes_a_running_player(self):
        # STOP_TALKBACK이 유실돼도 집 안에서 소리가 계속 나면 안 된다.
        talkback = FakeTalkback(None)
        talkback.running_snapshot = TalkbackSnapshot(
            STREAM_ID, True, NOW - timedelta(seconds=1), None
        )
        agent = agent_with(talkback)
        agent.talkback_retries = 3

        with patch("wj_device_agent.agent.utc_now", return_value=NOW):
            agent._monitor_talkback()

        self.assertEqual(talkback.stopped, [STREAM_ID])
        self.assertEqual(agent.talkback_retries, 0)

    def test_a_running_player_within_its_lease_is_left_alone(self):
        talkback = FakeTalkback(None)
        talkback.running_snapshot = TalkbackSnapshot(
            STREAM_ID, True, NOW + timedelta(seconds=10), None
        )
        agent = agent_with(talkback)

        with patch("wj_device_agent.agent.utc_now", return_value=NOW):
            agent._monitor_talkback()

        self.assertEqual(talkback.stopped, [])
        self.assertEqual(talkback.started, [])

    def test_retry_counter_resets_once_the_lease_is_gone(self):
        talkback = FakeTalkback(TalkbackSnapshot(STREAM_ID, False, None, 1))
        agent = agent_with(talkback)
        agent.talkback_retries = 5

        with patch("wj_device_agent.agent.utc_now", return_value=NOW):
            agent._monitor_talkback()

        self.assertEqual(talkback.started, [])
        self.assertEqual(agent.talkback_retries, 0)


if __name__ == "__main__":
    unittest.main()
