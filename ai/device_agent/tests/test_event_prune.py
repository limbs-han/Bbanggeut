import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "event_prune.py"
SPEC = importlib.util.spec_from_file_location("event_prune", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
event_prune = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = event_prune
SPEC.loader.exec_module(event_prune)


class EventPruneTest(unittest.TestCase):
    def event_dir(self, root: str) -> Path:
        path = Path(root) / "ai_events"
        path.mkdir()
        (path / event_prune.MARKER).touch()
        return path

    def test_storage_pressure_prunes_blocked_bundle_before_pending_event(self):
        with tempfile.TemporaryDirectory() as root:
            event_dir = self.event_dir(root)
            old = time.time() - 3600
            for suffix in (".trigger.json", ".mp4", ".upload-blocked.json"):
                path = event_dir / f"blocked{suffix}"
                path.write_bytes(b"b" * 16)
                os.utime(path, (old, old))
            pending = event_dir / "pending.trigger.json"
            pending.write_bytes(b"p" * 16)
            os.utime(pending, (old - 100, old - 100))

            usage = type("Usage", (), {"free": 10**12})()
            environment = {
                "EVENT_DIR": str(event_dir),
                "EVENT_RETENTION_DAYS": "7",
                "EVENT_BLOCKED_RETENTION_DAYS": "3",
                "EVENT_LOG_RETENTION_DAYS": "3",
                "EVENT_ACTIVE_GRACE_MINUTES": "15",
                "EVENT_MAX_GIB": "0.00000002",
                "EVENT_MIN_FREE_GIB": "1",
            }
            with (
                patch.dict(os.environ, environment, clear=False),
                patch.object(event_prune.shutil, "disk_usage", return_value=usage),
            ):
                self.assertEqual(event_prune.prune(now=time.time()), 0)

            self.assertFalse((event_dir / "blocked.mp4").exists())
            self.assertFalse((event_dir / "blocked.upload-blocked.json").exists())
            self.assertTrue(pending.exists())

    def test_retention_removes_blocked_bundle_sooner_than_pending_event(self):
        with tempfile.TemporaryDirectory() as root:
            event_dir = self.event_dir(root)
            four_days_old = time.time() - 4 * 86400
            for name in ("blocked.mp4", "blocked.upload-blocked.json", "pending.trigger.json"):
                path = event_dir / name
                path.touch()
                os.utime(path, (four_days_old, four_days_old))

            usage = type("Usage", (), {"free": 10**12})()
            environment = {
                "EVENT_DIR": str(event_dir),
                "EVENT_RETENTION_DAYS": "7",
                "EVENT_BLOCKED_RETENTION_DAYS": "3",
                "EVENT_LOG_RETENTION_DAYS": "3",
                "EVENT_ACTIVE_GRACE_MINUTES": "15",
                "EVENT_MAX_GIB": "2",
                "EVENT_MIN_FREE_GIB": "1",
            }
            with (
                patch.dict(os.environ, environment, clear=False),
                patch.object(event_prune.shutil, "disk_usage", return_value=usage),
            ):
                self.assertEqual(event_prune.prune(now=time.time()), 0)

            self.assertFalse((event_dir / "blocked.mp4").exists())
            self.assertTrue((event_dir / "pending.trigger.json").exists())

    def test_low_filesystem_free_space_uses_same_blocked_first_priority(self):
        with tempfile.TemporaryDirectory() as root:
            event_dir = self.event_dir(root)
            old = time.time() - 3600
            for name in ("blocked.upload-blocked.json", "pending.trigger.json"):
                path = event_dir / name
                path.write_bytes(b"data")
                os.utime(path, (old, old))

            low = type("Usage", (), {"free": 1})()
            recovered = type("Usage", (), {"free": 10**12})()
            environment = {
                "EVENT_DIR": str(event_dir),
                "EVENT_RETENTION_DAYS": "7",
                "EVENT_BLOCKED_RETENTION_DAYS": "3",
                "EVENT_LOG_RETENTION_DAYS": "3",
                "EVENT_ACTIVE_GRACE_MINUTES": "15",
                "EVENT_MAX_GIB": "2",
                "EVENT_MIN_FREE_GIB": "1",
            }
            with (
                patch.dict(os.environ, environment, clear=False),
                patch.object(
                    event_prune.shutil,
                    "disk_usage",
                    side_effect=[low, recovered, recovered],
                ),
            ):
                self.assertEqual(event_prune.prune(now=time.time()), 0)

            self.assertFalse((event_dir / "blocked.upload-blocked.json").exists())
            self.assertTrue((event_dir / "pending.trigger.json").exists())

    def test_refuses_directory_without_safety_marker(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(ValueError, "safety marker"):
                event_prune.safe_event_dir(str(Path(root) / "events"))

    def test_active_files_are_not_removed_even_under_storage_pressure(self):
        with tempfile.TemporaryDirectory() as root:
            event_dir = self.event_dir(root)
            active = event_dir / "active.upload-blocked.json"
            active.write_bytes(b"active")
            usage = type("Usage", (), {"free": 1})()
            environment = {
                "EVENT_DIR": str(event_dir),
                "EVENT_RETENTION_DAYS": "7",
                "EVENT_BLOCKED_RETENTION_DAYS": "3",
                "EVENT_LOG_RETENTION_DAYS": "3",
                "EVENT_ACTIVE_GRACE_MINUTES": "15",
                "EVENT_MAX_GIB": "2",
                "EVENT_MIN_FREE_GIB": "1",
            }
            with (
                patch.dict(os.environ, environment, clear=False),
                patch.object(event_prune.shutil, "disk_usage", return_value=usage),
            ):
                self.assertEqual(event_prune.prune(now=time.time()), 1)

            self.assertTrue(active.exists())

    def test_recent_file_write_protects_an_old_log_directory(self):
        with tempfile.TemporaryDirectory() as root:
            event_dir = self.event_dir(root)
            run_dir = event_dir / "logs" / "old-run"
            run_dir.mkdir(parents=True)
            old = time.time() - 10 * 86400
            os.utime(run_dir, (old, old))
            active_log = run_dir / "yamnet_diagnostics.jsonl"
            active_log.write_text("still running", encoding="utf-8")

            items, _ = event_prune.candidates(event_dir)

            self.assertEqual(len(items), 1)
            self.assertGreater(items[0].modified_at, time.time() - 60)


if __name__ == "__main__":
    unittest.main()
