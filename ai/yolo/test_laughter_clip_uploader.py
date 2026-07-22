"""Hardware-independent tests for laughter clip upload metadata."""

from __future__ import annotations

from datetime import timezone
from pathlib import Path
import tempfile
import unittest

from laughter_clip_uploader import instant, parse_instant, sha256


class LaughterClipUploaderTests(unittest.TestCase):
    def test_instant_round_trip_is_utc(self) -> None:
        parsed = parse_instant("2026-07-22T12:34:56.789Z")

        self.assertEqual(parsed.tzinfo, timezone.utc)
        self.assertEqual(instant(parsed), "2026-07-22T12:34:56.789Z")

    def test_sha256_reads_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "clip.mp4"
            path.write_bytes(b"laughter-clip")

            self.assertEqual(
                sha256(path),
                "4b7bc7960d9cc235d48df6fd56f7ec2f2aff937c616ac9f18865f84c43de58d8",
            )


if __name__ == "__main__":
    unittest.main()
