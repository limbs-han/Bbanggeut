"""Tests for private local wake-name profile registration."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from wake_name_profile import (
    load_and_validate_profile,
    register_profile,
)


class WakeNameProfileTests(unittest.TestCase):
    def test_registers_text_and_voice_samples_locally(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "voice.wav"
            source.write_bytes(b"RIFF-test-voice-data")
            profile_dir = root / "profile"

            profile_path = register_profile(
                profile_dir=profile_dir,
                phrase="윌리엄 제임스",
                locale="ko-KR",
                sample_paths=[source],
            )
            payload = load_and_validate_profile(profile_dir)

            self.assertEqual(profile_path, profile_dir / "profile.json")
            self.assertEqual(payload["wakePhrase"], "윌리엄 제임스")
            self.assertEqual(
                payload["recognitionMode"],
                "speaker-independent-local-asr",
            )
            self.assertEqual(len(payload["samples"]), 1)
            self.assertTrue(
                (profile_dir / payload["samples"][0]["path"]).is_file()
            )
            serialized = json.loads(profile_path.read_text(encoding="utf-8"))
            self.assertNotIn(str(source), json.dumps(serialized))

    def test_existing_profile_is_never_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "voice.wav"
            source.write_bytes(b"sample")
            profile_dir = root / "profile"
            register_profile(
                profile_dir=profile_dir,
                phrase="윌리엄",
                locale="ko-KR",
                sample_paths=[source],
            )

            with self.assertRaises(FileExistsError):
                register_profile(
                    profile_dir=profile_dir,
                    phrase="다른 이름",
                    locale="ko-KR",
                    sample_paths=[source],
                )

    def test_modified_sample_fails_validation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "voice.wav"
            source.write_bytes(b"sample")
            profile_dir = root / "profile"
            register_profile(
                profile_dir=profile_dir,
                phrase="윌리엄",
                locale="ko-KR",
                sample_paths=[source],
            )
            payload = json.loads(
                (profile_dir / "profile.json").read_text(encoding="utf-8")
            )
            (profile_dir / payload["samples"][0]["path"]).write_bytes(
                b"modified"
            )

            with self.assertRaises(ValueError):
                load_and_validate_profile(profile_dir)


if __name__ == "__main__":
    unittest.main()
