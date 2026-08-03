#!/usr/bin/env python3
"""Select and validate the operational YOLO model runtime on Jetson."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import sys
from typing import Callable


SUPPORTED_RUNTIMES = ("auto", "tensorrt", "pytorch")


class RuntimeSelectionError(RuntimeError):
    """Raised when the requested runtime cannot be used safely."""


@dataclass(frozen=True)
class RuntimeSelection:
    runtime: str
    model_path: Path
    fallback_reason: str | None = None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_model_file(path: Path, suffix: str) -> Path:
    resolved = path.expanduser().resolve()
    if not resolved.is_file():
        raise RuntimeSelectionError(f"model file not found: {resolved}")
    if resolved.suffix.lower() != suffix:
        raise RuntimeSelectionError(
            f"expected a {suffix} model, got: {resolved}"
        )
    return resolved


def validate_engine(
    engine_path: Path,
    expected_sha256: str,
    probe: Callable[[Path], None] | None,
) -> Path:
    resolved = validate_model_file(engine_path, ".engine")
    normalized_hash = expected_sha256.strip().lower()
    if normalized_hash:
        if len(normalized_hash) != 64 or any(
            character not in "0123456789abcdef"
            for character in normalized_hash
        ):
            raise RuntimeSelectionError(
                "YOLO TensorRT engine SHA-256 must contain 64 hex characters"
            )
        actual_hash = sha256_file(resolved)
        if actual_hash != normalized_hash:
            raise RuntimeSelectionError(
                "TensorRT engine SHA-256 mismatch: "
                f"expected={normalized_hash} actual={actual_hash}"
            )
    if probe is not None:
        try:
            probe(resolved)
        except Exception as error:
            raise RuntimeSelectionError(
                f"TensorRT startup probe failed: {error}"
            ) from error
    return resolved


def select_runtime(
    requested_runtime: str,
    engine_path: Path,
    pytorch_path: Path,
    *,
    expected_engine_sha256: str = "",
    engine_probe: Callable[[Path], None] | None = None,
) -> RuntimeSelection:
    requested = requested_runtime.strip().lower()
    if requested not in SUPPORTED_RUNTIMES:
        choices = ", ".join(SUPPORTED_RUNTIMES)
        raise RuntimeSelectionError(
            f"unsupported YOLO runtime {requested_runtime!r}; choose: {choices}"
        )

    if requested == "pytorch":
        return RuntimeSelection(
            runtime="pytorch",
            model_path=validate_model_file(pytorch_path, ".pt"),
        )

    try:
        selected_engine = validate_engine(
            engine_path,
            expected_engine_sha256,
            engine_probe,
        )
    except RuntimeSelectionError as error:
        if requested == "tensorrt":
            raise
        return RuntimeSelection(
            runtime="pytorch",
            model_path=validate_model_file(pytorch_path, ".pt"),
            fallback_reason=str(error),
        )

    return RuntimeSelection(
        runtime="tensorrt",
        model_path=selected_engine,
    )


def probe_tensorrt_engine(path: Path, device: str, image_size: int) -> None:
    import numpy as np
    from ultralytics import YOLO

    image = np.zeros((image_size, image_size, 3), dtype=np.uint8)
    model = YOLO(str(path), task="detect")
    results = model.predict(
        source=image,
        imgsz=image_size,
        device=device,
        verbose=False,
    )
    if len(results) != 1:
        raise RuntimeError(
            f"expected one TensorRT probe result, received {len(results)}"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Prefer a validated TensorRT engine and safely fall back to the "
            "packaged PyTorch model when runtime=auto."
        )
    )
    parser.add_argument("--runtime", choices=SUPPORTED_RUNTIMES, default="auto")
    parser.add_argument("--engine-path", type=Path, required=True)
    parser.add_argument("--pytorch-path", type=Path, required=True)
    parser.add_argument("--engine-sha256", default="")
    parser.add_argument("--probe-device", default="0")
    parser.add_argument("--probe-image-size", type=int, default=640)
    parser.add_argument("--skip-engine-probe", action="store_true")
    parser.add_argument(
        "--result-file",
        type=Path,
        required=True,
        help="Write the selected runtime and model path as one TSV record.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.probe_image_size <= 0:
        print(
            "[YOLO_RUNTIME] probe image size must be positive",
            file=sys.stderr,
        )
        return 2

    probe = None
    if not args.skip_engine_probe:
        probe = lambda path: probe_tensorrt_engine(
            path,
            args.probe_device,
            args.probe_image_size,
        )

    try:
        selection = select_runtime(
            args.runtime,
            args.engine_path,
            args.pytorch_path,
            expected_engine_sha256=args.engine_sha256,
            engine_probe=probe,
        )
    except RuntimeSelectionError as error:
        print(f"[YOLO_RUNTIME] ERROR: {error}", file=sys.stderr)
        return 2

    print(f"[YOLO_RUNTIME] requested={args.runtime}", file=sys.stderr)
    if selection.fallback_reason:
        print(
            "[YOLO_RUNTIME] TensorRT unavailable; using PyTorch fallback: "
            f"{selection.fallback_reason}",
            file=sys.stderr,
        )
    print(
        "[YOLO_RUNTIME] "
        f"selected={selection.runtime} model={selection.model_path}",
        file=sys.stderr,
    )
    result_file = args.result_file.expanduser().resolve()
    result_file.parent.mkdir(parents=True, exist_ok=True)
    temporary_file = result_file.with_name(result_file.name + ".tmp")
    temporary_file.write_text(
        f"{selection.runtime}\t{selection.model_path}\n",
        encoding="utf-8",
    )
    os.replace(temporary_file, result_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
