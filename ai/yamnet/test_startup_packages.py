import builtins
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import yamnet_laughter_detect_jetson as detector


require_audio_packages = detector.require_audio_packages


class StartupPackageTests(unittest.TestCase):
    def test_rtsp_path_skips_sounddevice_import(self) -> None:
        original_import = builtins.__import__
        fake_numpy = SimpleNamespace(__name__="numpy")

        def guarded_import(name, *args, **kwargs):
            if name == "sounddevice":
                raise AssertionError("sounddevice must not be imported")
            return original_import(name, *args, **kwargs)

        with (
            patch.dict(sys.modules, {"numpy": fake_numpy}),
            patch("builtins.__import__", side_effect=guarded_import),
        ):
            numpy_module, sounddevice_module = (
                require_audio_packages(need_sounddevice=False)
            )

        self.assertEqual(numpy_module.__name__, "numpy")
        self.assertIsNone(sounddevice_module)

    def test_local_audio_path_imports_sounddevice(self) -> None:
        fake_numpy = SimpleNamespace(__name__="numpy")
        fake_sounddevice = object()
        with patch.dict(
            sys.modules,
            {"numpy": fake_numpy, "sounddevice": fake_sounddevice},
        ):
            _, sounddevice_module = require_audio_packages(
                need_sounddevice=True
            )

        self.assertIs(sounddevice_module, fake_sounddevice)

    def test_default_keeps_local_audio_compatibility(self) -> None:
        fake_numpy = SimpleNamespace(__name__="numpy")
        fake_sounddevice = object()
        with patch.dict(
            sys.modules,
            {"numpy": fake_numpy, "sounddevice": fake_sounddevice},
        ):
            _, sounddevice_module = require_audio_packages()

        self.assertIs(sounddevice_module, fake_sounddevice)

    def test_main_skips_sounddevice_for_rtsp(self) -> None:
        args = SimpleNamespace(list_devices=False, stream_url="rtsp://camera/ai")
        numpy_module = object()
        with (
            patch.object(detector, "parse_args", return_value=args),
            patch.object(
                detector,
                "require_audio_packages",
                return_value=(numpy_module, None),
            ) as require_packages,
            patch.object(detector, "run_detector") as run_detector,
        ):
            detector.main()

        require_packages.assert_called_once_with(need_sounddevice=False)
        run_detector.assert_called_once_with(args, numpy_module, None)

    def test_main_loads_sounddevice_for_device_listing(self) -> None:
        args = SimpleNamespace(list_devices=True, stream_url="rtsp://camera/ai")
        fake_sounddevice = Mock()
        with (
            patch.object(detector, "parse_args", return_value=args),
            patch.object(
                detector,
                "require_audio_packages",
                return_value=(object(), fake_sounddevice),
            ) as require_packages,
        ):
            detector.main()

        require_packages.assert_called_once_with(need_sounddevice=True)
        fake_sounddevice.query_devices.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
