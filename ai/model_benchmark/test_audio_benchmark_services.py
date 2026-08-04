import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parent / "audio_benchmark_services.sh"
MANAGED_SERVICES = (
    "wj-device-agent.service",
    "wj-local-recording.service",
    "wj-edge-ai-recording.service",
    "wj-servo-controller.service",
)
CAPTURE_SERVICES = (
    "wj-mediamtx-local.service",
    "wj-media-source.service",
)


class AudioBenchmarkServicesTests(unittest.TestCase):
    def setUp(self) -> None:
        if os.name == "nt":
            self.skipTest("service lifecycle scenario runs on the Linux CI agent")
        self.bash = shutil.which("bash")
        if self.bash is None:
            self.skipTest("bash is not available")

    def prepare_environment(self, root: Path) -> tuple[dict[str, str], Path]:
        fake_bin = root / "bin"
        state_root = root / "states"
        fake_bin.mkdir()
        state_root.mkdir()

        systemctl = fake_bin / "systemctl"
        systemctl.write_text(
            """#!/usr/bin/env bash
set -Eeuo pipefail
state_root="${FAKE_SYSTEMD_STATE_ROOT:?}"
command="${1:?}"
shift
case "$command" in
  is-active)
    state="$(cat "$state_root/$1" 2>/dev/null || echo inactive)"
    echo "$state"
    test "$state" = active
    ;;
  stop)
    for service in "$@"; do printf 'inactive\n' >"$state_root/$service"; done
    ;;
  start)
    for service in "$@"; do printf 'active\n' >"$state_root/$service"; done
    ;;
  reset-failed)
    ;;
  *)
    echo "unsupported fake systemctl command: $command" >&2
    exit 2
    ;;
esac
""",
            encoding="utf-8",
        )
        sudo = fake_bin / "sudo"
        sudo.write_text(
            "#!/usr/bin/env bash\nset -Eeuo pipefail\nexec \"$@\"\n",
            encoding="utf-8",
        )
        systemctl.chmod(systemctl.stat().st_mode | stat.S_IXUSR)
        sudo.chmod(sudo.stat().st_mode | stat.S_IXUSR)

        for service in MANAGED_SERVICES:
            (state_root / service).write_text("active\n", encoding="utf-8")
        for service in CAPTURE_SERVICES:
            (state_root / service).write_text("inactive\n", encoding="utf-8")

        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
        environment["FAKE_SYSTEMD_STATE_ROOT"] = str(state_root)
        environment["AUDIO_BENCHMARK_STATE_FILE"] = str(root / "state.txt")
        return environment, state_root

    def run_service_script(
        self,
        environment: dict[str, str],
        *arguments: str,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [self.bash, str(SCRIPT), *arguments],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        )

    @staticmethod
    def service_state(state_root: Path, service: str) -> str:
        return (state_root / service).read_text(encoding="utf-8").strip()

    def test_restore_keeps_servo_stopped_without_explicit_opt_in(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment, state_root = self.prepare_environment(root)

            self.run_service_script(environment, "isolate")
            self.assertTrue(
                all(
                    self.service_state(state_root, service) == "inactive"
                    for service in MANAGED_SERVICES
                )
            )
            self.assertTrue(
                all(
                    self.service_state(state_root, service) == "active"
                    for service in CAPTURE_SERVICES
                )
            )

            restored = self.run_service_script(environment, "restore")
            self.assertIn("SERVO_RESTORE_SKIPPED", restored.stdout)
            self.assertEqual(
                self.service_state(
                    state_root,
                    "wj-servo-controller.service",
                ),
                "inactive",
            )
            for service in MANAGED_SERVICES[:-1]:
                self.assertEqual(
                    self.service_state(state_root, service),
                    "active",
                )
            state_file = Path(environment["AUDIO_BENCHMARK_STATE_FILE"])
            self.assertFalse(state_file.exists())

    def test_restore_servo_requires_explicit_restore_option(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            environment, state_root = self.prepare_environment(root)

            self.run_service_script(environment, "isolate")
            self.run_service_script(environment, "restore", "--restore-servo")

            self.assertEqual(
                self.service_state(
                    state_root,
                    "wj-servo-controller.service",
                ),
                "active",
            )


if __name__ == "__main__":
    unittest.main()
