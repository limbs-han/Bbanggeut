from pathlib import Path
import unittest


class MediaClockGuardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        root = Path(__file__).resolve().parents[1]
        cls.script = (root / "media-clock-guard.sh").read_text(encoding="utf-8")
        cls.unit = (root / "wj-media-clock-guard.service").read_text(encoding="utf-8")
        cls.installer = (root / "install-local-media.sh").read_text(encoding="utf-8")

    def test_waits_for_the_real_synchronization_flag(self) -> None:
        # timesyncd 가 기록된 시각으로 되돌려 놓는 것만으로는 동기화가 아니다.
        # 이 파일은 실제 NTP 동기화에 성공해야 생긴다.
        self.assertIn("/run/systemd/timesync/synchronized", self.script)

    def test_jump_is_measured_against_the_monotonic_clock(self) -> None:
        # 벽시계만 보면 점프를 점프로 알 수 없다. 단조 시계와의 차이가 점프다.
        self.assertIn("/proc/uptime", self.script)

    def test_small_corrections_do_not_restart_the_chain(self) -> None:
        self.assertIn("CLOCK_GUARD_JUMP_THRESHOLD_SECONDS", self.script)

    def test_units_are_restarted_in_dependency_order(self) -> None:
        units = self.script[self.script.index("CLOCK_GUARD_UNITS") :]
        source = units.index("wj-media-source.service")
        mediamtx = units.index("wj-mediamtx-local.service")
        recording = units.index("wj-local-recording.service")
        self.assertLess(source, mediamtx)
        self.assertLess(mediamtx, recording)

    def test_offline_boot_does_not_block_forever(self) -> None:
        self.assertIn("CLOCK_GUARD_TIMEOUT_SECONDS", self.script)
        # 유닛의 시작 상한이 스크립트의 대기 상한보다 짧으면 systemd 가 먼저
        # 죽인다. 두 값이 함께 움직여야 한다.
        self.assertIn("TimeoutStartSec=1200", self.unit)
        self.assertIn("CLOCK_GUARD_TIMEOUT_SECONDS:=900", self.script)

    def test_installer_stages_the_guard(self) -> None:
        self.assertIn("media-clock-guard.sh", self.installer)
        self.assertIn("wj-media-clock-guard.service", self.installer)


if __name__ == "__main__":
    unittest.main()
