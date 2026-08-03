#!/usr/bin/env python3
"""Run one audio tagging model and emit the common benchmark JSONL contract."""

from __future__ import annotations

import argparse
from contextlib import contextmanager, nullcontext
import csv
from datetime import datetime, timezone
import hashlib
import importlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import time
from typing import Any, Iterator, Sequence

from vision_accuracy_runner import TegrastatsMonitor, summarize_resources


SCHEMA_VERSION = "0.1"
LAUGHTER_CLASS_NAMES = (
    "Laughter",
    "Baby laughter",
    "Giggle",
    "Snicker",
    "Belly laugh",
    "Chuckle, chortle",
)
CLAP_CLASS_NAMES = (
    "Clapping",
    "Applause",
)
EVENT_CLASS_NAMES = {
    "laughter": LAUGHTER_CLASS_NAMES,
    "clap": CLAP_CLASS_NAMES,
}
MODEL_RUNTIMES = {
    "yamnet-tflite": "tflite",
    "efficientat-mn10": "pytorch",
    "panns-cnn10": "pytorch",
}


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def git_commit(repository: Path | None) -> str | None:
    if repository is None or not (repository / ".git").exists():
        return None
    import subprocess

    completed = subprocess.run(
        ["git", "-C", str(repository), "rev-parse", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    value = completed.stdout.strip()
    return value if completed.returncode == 0 and value else None


def quantize_tensor(values: Any, detail: dict[str, Any]) -> Any:
    import numpy as np

    dtype = np.dtype(detail["dtype"])
    array = np.asarray(values, dtype=np.float32)
    if not np.issubdtype(dtype, np.integer):
        return array.astype(dtype)
    scale, zero_point = detail.get("quantization", (0.0, 0))
    if not scale:
        raise ValueError("quantized TFLite input has no scale")
    limits = np.iinfo(dtype)
    quantized = np.rint(array / float(scale) + int(zero_point))
    return np.clip(quantized, limits.min, limits.max).astype(dtype)


def dequantize_tensor(values: Any, detail: dict[str, Any]) -> Any:
    import numpy as np

    array = np.asarray(values)
    if not np.issubdtype(array.dtype, np.integer):
        return array.astype(np.float32)
    scale, zero_point = detail.get("quantization", (0.0, 0))
    if not scale:
        raise ValueError("quantized TFLite output has no scale")
    return (array.astype(np.float32) - int(zero_point)) * float(scale)


def load_class_names(path: Path) -> list[str]:
    with path.open("r", encoding="utf-8-sig", newline="") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames is None:
            raise ValueError(f"class map has no header: {path}")
        name_field = next(
            (
                field
                for field in ("display_name", "label", "name")
                if field in reader.fieldnames
            ),
            None,
        )
        if name_field is None:
            raise ValueError(
                f"class map must include display_name, label, or name: {path}"
            )
        rows = list(reader)
        index_field = next(
            (field for field in ("index", "class_index") if field in reader.fieldnames),
            None,
        )
        if index_field is None:
            names = [str(row[name_field]).strip() for row in rows]
        else:
            indexed: dict[int, str] = {}
            for row in rows:
                try:
                    index = int(row[index_field])
                except (TypeError, ValueError) as error:
                    raise ValueError(f"class map has an invalid index: {path}") from error
                if index < 0 or index in indexed:
                    raise ValueError(f"class map has a duplicate index: {path}")
                indexed[index] = str(row[name_field]).strip()
            expected = set(range(len(indexed)))
            if set(indexed) != expected:
                raise ValueError(f"class map indices are not contiguous: {path}")
            names = [indexed[index] for index in range(len(indexed))]
    if not names or any(not name for name in names):
        raise ValueError(f"class map contains an empty label: {path}")
    return names


def event_class_indices(
    class_names: Sequence[str],
    event_type: str,
) -> tuple[int, ...]:
    expected_names = EVENT_CLASS_NAMES.get(event_type)
    if expected_names is None:
        raise ValueError(f"unsupported audio event type: {event_type}")
    lookup = {name: index for index, name in enumerate(class_names)}
    missing = [name for name in expected_names if name not in lookup]
    if missing:
        raise ValueError(
            f"class map is missing {event_type} labels: " + ", ".join(missing)
        )
    return tuple(lookup[name] for name in expected_names)


def laughter_indices(class_names: Sequence[str]) -> tuple[int, ...]:
    """Backward-compatible helper used by existing tests and callers."""

    return event_class_indices(class_names, "laughter")


def load_manifest_samples(
    dataset_root: Path,
    *,
    splits: set[str],
    allow_provisional: bool,
) -> list[dict[str, Any]]:
    manifest_path = dataset_root / "dataset.json"
    if not manifest_path.is_file():
        raise ValueError(f"dataset manifest does not exist: {manifest_path}")
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    rows = payload.get("samples") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        raise ValueError("dataset manifest must contain a samples array")

    selected: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ValueError(f"samples[{index}] must be an object")
        if row.get("split") not in splits:
            continue
        sample_id = row.get("sampleId")
        media_value = row.get("media")
        review = row.get("review")
        if not isinstance(sample_id, str) or not sample_id:
            raise ValueError(f"samples[{index}].sampleId is invalid")
        if sample_id in seen:
            raise ValueError(f"duplicate sampleId: {sample_id}")
        seen.add(sample_id)
        if not isinstance(media_value, str):
            raise ValueError(f"sample {sample_id} has no media path")
        review_status = review.get("status") if isinstance(review, dict) else None
        if review_status != "verified" and not allow_provisional:
            raise ValueError(f"sample {sample_id} is not verified")
        media_path = (dataset_root / media_value).resolve()
        try:
            media_path.relative_to(dataset_root)
        except ValueError as error:
            raise ValueError(f"sample {sample_id} media escapes dataset root") from error
        if not media_path.is_file():
            raise ValueError(f"sample {sample_id} media is missing: {media_value}")
        if media_path.suffix.lower() != ".wav":
            raise ValueError(f"sample {sample_id} media must be a WAV file")
        expected_hash = row.get("sha256")
        if isinstance(expected_hash, str) and sha256_file(media_path) != expected_hash:
            raise ValueError(f"sample {sample_id} media checksum mismatch")
        selected.append({"sampleId": sample_id, "media": media_path})
    if not selected:
        raise ValueError(f"dataset has no samples for splits: {', '.join(sorted(splits))}")
    return selected


def window_waveform(
    waveform: Any,
    *,
    sample_rate: int,
    window_seconds: float,
    hop_seconds: float,
) -> Iterator[tuple[int, Any]]:
    import numpy as np

    window_samples = int(round(sample_rate * window_seconds))
    hop_samples = int(round(sample_rate * hop_seconds))
    if window_samples <= 0 or hop_samples <= 0:
        raise ValueError("window and hop must contain at least one sample")
    values = np.asarray(waveform, dtype=np.float32).reshape(-1)
    if values.size == 0:
        raise ValueError("audio waveform is empty")
    start = 0
    index = 0
    while start < values.size:
        window = values[start : start + window_samples]
        if window.size < window_samples:
            window = np.pad(window, (0, window_samples - window.size))
        yield index, window.astype(np.float32, copy=False)
        if start + window_samples >= values.size:
            break
        start += hop_samples
        index += 1


@contextmanager
def repository_import_path(repository: Path) -> Iterator[None]:
    repository = repository.resolve()
    previous_directory = Path.cwd()
    previous_path = list(sys.path)
    previous_modules = dict(sys.modules)
    os.chdir(repository)
    sys.path.insert(0, str(repository))
    sys.path.insert(0, str(repository / "pytorch"))
    try:
        yield
    finally:
        os.chdir(previous_directory)
        sys.path[:] = previous_path
        missing = object()
        for name, module in tuple(sys.modules.items()):
            previous = previous_modules.get(name, missing)
            if previous is module:
                continue
            module_file = getattr(module, "__file__", None)
            if not module_file:
                continue
            try:
                Path(module_file).resolve().relative_to(repository)
            except (OSError, ValueError):
                continue
            if previous is missing:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous


def checkpoint_state_dict(checkpoint: Any) -> dict[str, Any]:
    if not isinstance(checkpoint, dict):
        raise ValueError("PyTorch checkpoint must be a dictionary")
    for key in ("model", "state_dict"):
        value = checkpoint.get(key)
        if isinstance(value, dict):
            return value
    if checkpoint and all(isinstance(key, str) for key in checkpoint):
        return checkpoint
    raise ValueError("PyTorch checkpoint has no model state dictionary")


def load_module_file(path: Path, name: str) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load Python module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Predictor:
    sample_rate: int
    class_names: list[str]
    precision: str

    def predict(self, waveform: Any) -> tuple[Any, float]:
        raise NotImplementedError


class YamnetTflitePredictor(Predictor):
    sample_rate = 16000

    def __init__(self, model_path: Path, class_map: Path, threads: int) -> None:
        import numpy as np

        try:
            from tflite_runtime.interpreter import Interpreter
        except ImportError:
            try:
                import tensorflow as tf
            except ImportError as error:
                raise RuntimeError(
                    "YAMNet requires tflite-runtime or TensorFlow"
                ) from error
            Interpreter = tf.lite.Interpreter
        self.class_names = load_class_names(class_map)
        self.interpreter = Interpreter(
            model_path=str(model_path),
            num_threads=max(1, threads),
        )
        self.interpreter.allocate_tensors()
        self.input = self.interpreter.get_input_details()[0]
        self.precision = np.dtype(self.input["dtype"]).name
        outputs = self.interpreter.get_output_details()
        matches = [
            output
            for output in outputs
            if int(output["shape"][-1]) == len(self.class_names)
        ]
        if len(matches) != 1:
            raise ValueError("could not identify the YAMNet class score output")
        self.output = matches[0]
        self.input_samples = 1
        for size in self.input["shape"]:
            self.input_samples *= int(size)

    def predict(self, waveform: Any) -> tuple[Any, float]:
        import numpy as np

        values = np.asarray(waveform, dtype=np.float32).reshape(-1)
        if values.size != self.input_samples:
            raise ValueError(
                f"YAMNet input requires {self.input_samples} samples, got {values.size}"
            )
        tensor = quantize_tensor(values.reshape(self.input["shape"]), self.input)
        self.interpreter.set_tensor(self.input["index"], tensor)
        started = time.perf_counter()
        self.interpreter.invoke()
        latency_ms = (time.perf_counter() - started) * 1000.0
        scores = dequantize_tensor(
            self.interpreter.get_tensor(self.output["index"]),
            self.output,
        )
        scores = np.asarray(scores, dtype=np.float32).reshape(-1, len(self.class_names))
        return scores.max(axis=0), latency_ms


class EfficientAtPredictor(Predictor):
    sample_rate = 32000

    def __init__(
        self,
        model_path: Path,
        repository: Path,
        class_map: Path,
        device_name: str,
    ) -> None:
        import torch

        self.torch = torch
        self.device = torch.device(device_name)
        self.precision = "fp16-autocast" if self.device.type == "cuda" else "fp32"
        self.class_names = load_class_names(class_map)
        with repository_import_path(repository):
            get_model = importlib.import_module("models.mn.model").get_model
            preprocess = importlib.import_module("models.preprocess")
            self.model = get_model(
                num_classes=len(self.class_names),
                pretrained_name=None,
                width_mult=1.0,
            )
            self.mel = preprocess.AugmentMelSTFT(
                n_mels=128,
                sr=self.sample_rate,
                win_length=800,
                hopsize=320,
            )
        checkpoint = torch.load(model_path, map_location="cpu", weights_only=False)
        self.model.load_state_dict(checkpoint_state_dict(checkpoint))
        self.model.to(self.device).eval()
        self.mel.to(self.device).eval()

    def predict(self, waveform: Any) -> tuple[Any, float]:
        torch = self.torch
        values = torch.from_numpy(waveform[None, :]).to(self.device)
        if self.device.type == "cuda":
            torch.cuda.synchronize(self.device)
        started = time.perf_counter()
        precision = (
            torch.autocast(device_type="cuda", dtype=torch.float16)
            if self.device.type == "cuda"
            else nullcontext()
        )
        with torch.no_grad(), precision:
            spectrogram = self.mel(values)
            logits, _ = self.model(spectrogram.unsqueeze(0))
            scores = torch.sigmoid(logits.float()).squeeze()
        if self.device.type == "cuda":
            torch.cuda.synchronize(self.device)
        latency_ms = (time.perf_counter() - started) * 1000.0
        return scores.detach().cpu().numpy(), latency_ms


class PannsCnn10Predictor(Predictor):
    sample_rate = 32000

    def __init__(
        self,
        model_path: Path,
        repository: Path,
        class_map: Path,
        device_name: str,
    ) -> None:
        import torch

        self.torch = torch
        self.device = torch.device(device_name)
        self.precision = "fp16-autocast" if self.device.type == "cuda" else "fp32"
        self.class_names = load_class_names(class_map)
        with repository_import_path(repository):
            model_module = load_module_file(
                repository / "pytorch" / "models.py",
                "_wj_panns_cnn10_models",
            )
            self.model = model_module.Cnn10(
                sample_rate=self.sample_rate,
                window_size=1024,
                hop_size=320,
                mel_bins=64,
                fmin=50,
                fmax=14000,
                classes_num=len(self.class_names),
            )
        checkpoint = torch.load(model_path, map_location="cpu", weights_only=False)
        self.model.load_state_dict(checkpoint_state_dict(checkpoint))
        self.model.to(self.device).eval()

    def predict(self, waveform: Any) -> tuple[Any, float]:
        torch = self.torch
        values = torch.from_numpy(waveform[None, :]).to(self.device)
        if self.device.type == "cuda":
            torch.cuda.synchronize(self.device)
        started = time.perf_counter()
        precision = (
            torch.autocast(device_type="cuda", dtype=torch.float16)
            if self.device.type == "cuda"
            else nullcontext()
        )
        with torch.no_grad(), precision:
            output = self.model(values)
            scores = output["clipwise_output"].float().squeeze()
        if self.device.type == "cuda":
            torch.cuda.synchronize(self.device)
        latency_ms = (time.perf_counter() - started) * 1000.0
        return scores.detach().cpu().numpy(), latency_ms


def default_class_map(kind: str, repository: Path | None) -> Path | None:
    if kind == "efficientat-mn10" and repository is not None:
        return repository / "metadata" / "class_labels_indices.csv"
    if kind == "panns-cnn10" and repository is not None:
        return repository / "metadata" / "class_labels_indices.csv"
    return None


def build_predictor(args: argparse.Namespace, class_map: Path) -> Predictor:
    if args.model_kind == "yamnet-tflite":
        return YamnetTflitePredictor(args.model, class_map, args.threads)
    if args.source_repo is None:
        raise ValueError(f"{args.model_kind} requires --source-repo")
    if args.model_kind == "efficientat-mn10":
        return EfficientAtPredictor(
            args.model,
            args.source_repo,
            class_map,
            args.device,
        )
    return PannsCnn10Predictor(
        args.model,
        args.source_repo,
        class_map,
        args.device,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", type=Path, required=True)
    parser.add_argument(
        "--model-kind",
        choices=("yamnet-tflite", "efficientat-mn10", "panns-cnn10"),
        required=True,
    )
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--source-repo", type=Path)
    parser.add_argument("--class-map", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--progress", type=Path)
    parser.add_argument("--metadata-output", type=Path)
    parser.add_argument("--resources", type=Path)
    parser.add_argument("--model-name")
    parser.add_argument("--split", action="append", choices=("train", "validation", "test"))
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--threads", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    parser.add_argument("--window-seconds", type=float, default=0.975)
    parser.add_argument("--hop-seconds", type=float, default=0.4875)
    parser.add_argument("--warmup-windows", type=int, default=3)
    parser.add_argument("--allow-provisional", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    dataset_root = args.dataset_root.expanduser().resolve()
    args.model = args.model.expanduser().resolve()
    args.output = args.output.expanduser().resolve()
    args.progress = (
        args.progress.expanduser().resolve()
        if args.progress
        else args.output.parent / "progress.json"
    )
    args.metadata_output = (
        args.metadata_output.expanduser().resolve()
        if args.metadata_output
        else args.output.parent / "prediction-metadata.json"
    )
    args.resources = (
        args.resources.expanduser().resolve()
        if args.resources
        else args.output.parent / "resources.log"
    )
    args.source_repo = (
        args.source_repo.expanduser().resolve() if args.source_repo else None
    )
    if not args.model.is_file():
        raise SystemExit(f"ERROR: model file does not exist: {args.model}")
    if args.source_repo is not None and not args.source_repo.is_dir():
        raise SystemExit(f"ERROR: source repository does not exist: {args.source_repo}")
    class_map = (
        args.class_map.expanduser().resolve()
        if args.class_map
        else default_class_map(args.model_kind, args.source_repo)
    )
    if class_map is None or not class_map.is_file():
        raise SystemExit("ERROR: a valid --class-map is required")
    if args.output.exists():
        raise SystemExit(f"ERROR: output already exists: {args.output}")
    if args.window_seconds <= 0 or args.hop_seconds <= 0:
        raise SystemExit("ERROR: window and hop seconds must be positive")
    if args.warmup_windows < 0:
        raise SystemExit("ERROR: warmup windows cannot be negative")

    try:
        samples = load_manifest_samples(
            dataset_root,
            splits=set(args.split or ["validation", "test"]),
            allow_provisional=args.allow_provisional,
        )
        predictor = build_predictor(args, class_map)
        event_indices = {
            event_type: event_class_indices(predictor.class_names, event_type)
            for event_type in EVENT_CLASS_NAMES
        }
    except (ImportError, json.JSONDecodeError, OSError, RuntimeError, ValueError) as error:
        raise SystemExit(f"ERROR: {error}") from error

    import librosa
    import numpy as np
    import soundfile as sf

    expected_samples = int(round(predictor.sample_rate * args.window_seconds))
    if isinstance(predictor, YamnetTflitePredictor):
        expected_samples = predictor.input_samples
        effective_window_seconds = expected_samples / predictor.sample_rate
    else:
        effective_window_seconds = args.window_seconds

    zero_window = np.zeros(expected_samples, dtype=np.float32)
    for _ in range(args.warmup_windows):
        predictor.predict(zero_window)

    model_name = args.model_name or args.model_kind
    run_id = args.output.parent.name
    progress_base = {
        "schemaVersion": SCHEMA_VERSION,
        "runId": run_id,
        "component": "audio",
        "model": model_name,
        "runtime": MODEL_RUNTIMES[args.model_kind],
        "dataset": dataset_root.name,
    }
    atomic_write_json(
        args.progress,
        {
            **progress_base,
            "updatedAt": utc_now(),
            "status": "running",
            "progress": {
                "completedSamples": 0,
                "totalSamples": len(samples),
                "percent": 0.0,
                "stage": "predicting",
            },
        },
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    row_count = 0
    completed_samples = 0
    try:
        with temporary.open("w", encoding="utf-8") as destination:
            with TegrastatsMonitor(args.resources):
                for sample_number, sample in enumerate(samples, start=1):
                    audio_info = sf.info(str(sample["media"]))
                    if audio_info.format != "WAV" or not audio_info.subtype.startswith(
                        "PCM"
                    ):
                        raise ValueError(
                            f"sample {sample['sampleId']} must use lossless PCM WAV"
                        )
                    waveform, _ = librosa.load(
                        sample["media"],
                        sr=predictor.sample_rate,
                        mono=True,
                        dtype=np.float32,
                    )
                    duration_seconds = len(waveform) / predictor.sample_rate
                    for window_index, window in window_waveform(
                        waveform,
                        sample_rate=predictor.sample_rate,
                        window_seconds=effective_window_seconds,
                        hop_seconds=args.hop_seconds,
                    ):
                        scores, latency_ms = predictor.predict(window)
                        values = np.asarray(scores, dtype=np.float32).reshape(-1)
                        if values.size != len(predictor.class_names):
                            raise ValueError(
                                "model score count does not match the class map"
                            )
                        event_scores = {
                            event_type: float(
                                max(values[index] for index in indices)
                            )
                            for event_type, indices in event_indices.items()
                        }
                        top_index = int(values.argmax())
                        row = {
                            "schemaVersion": SCHEMA_VERSION,
                            "sampleId": sample["sampleId"],
                            "windowIndex": window_index,
                            "score": round(event_scores["laughter"], 8),
                            "scores": {
                                event_type: round(score, 8)
                                for event_type, score in event_scores.items()
                            },
                            "latencyMs": round(latency_ms, 4),
                            "durationSeconds": round(duration_seconds, 6),
                            "offsetSeconds": round(
                                window_index * args.hop_seconds,
                                6,
                            ),
                            "topClass": predictor.class_names[top_index],
                        }
                        destination.write(
                            json.dumps(row, ensure_ascii=False) + "\n"
                        )
                        row_count += 1
                    atomic_write_json(
                        args.progress,
                        {
                            **progress_base,
                            "updatedAt": utc_now(),
                            "status": "running",
                            "progress": {
                                "completedSamples": sample_number,
                                "totalSamples": len(samples),
                                "percent": round(
                                    sample_number / len(samples) * 100.0,
                                    3,
                                ),
                                "stage": "predicting",
                            },
                            "current": {"sampleId": sample["sampleId"]},
                        },
                    )
                    completed_samples = sample_number
    except Exception as error:
        temporary.unlink(missing_ok=True)
        atomic_write_json(
            args.progress,
            {
                **progress_base,
                "updatedAt": utc_now(),
                "status": "failed",
                "progress": {
                    "completedSamples": completed_samples,
                    "totalSamples": len(samples),
                    "percent": round(
                        completed_samples / len(samples) * 100.0,
                        3,
                    ),
                    "stage": "failed",
                },
                "error": str(error),
            },
        )
        raise
    temporary.replace(args.output)
    atomic_write_json(
        args.metadata_output,
        {
            "schemaVersion": SCHEMA_VERSION,
            "model": {
                "name": model_name,
                "kind": args.model_kind,
                "path": str(args.model),
                "sizeBytes": args.model.stat().st_size,
                "sha256": sha256_file(args.model),
            },
            "source": {
                "repository": str(args.source_repo) if args.source_repo else None,
                "commit": git_commit(args.source_repo),
            },
            "classMap": {
                "path": str(class_map),
                "sha256": sha256_file(class_map),
                "classCount": len(predictor.class_names),
                "eventClasses": {
                    event_type: [
                        {"index": index, "name": predictor.class_names[index]}
                        for index in indices
                    ]
                    for event_type, indices in event_indices.items()
                },
            },
            "configuration": {
                "sampleRate": predictor.sample_rate,
                "windowSeconds": effective_window_seconds,
                "hopSeconds": args.hop_seconds,
                "warmupWindows": args.warmup_windows,
                "splits": args.split or ["validation", "test"],
                "device": args.device,
                "precision": predictor.precision,
            },
            "dataset": {
                "path": str(dataset_root),
                "manifestSha256": sha256_file(dataset_root / "dataset.json"),
                "sampleCount": len(samples),
            },
            "predictionCount": row_count,
            "resources": summarize_resources(args.resources),
        },
    )
    atomic_write_json(
        args.progress,
        {
            **progress_base,
            "updatedAt": utc_now(),
            "status": "completed",
            "progress": {
                "completedSamples": len(samples),
                "totalSamples": len(samples),
                "percent": 100.0,
                "stage": "predictions-completed",
            },
        },
    )
    print(
        f"PASS: audio predictions written model={args.model_kind} "
        f"samples={len(samples)} windows={row_count}"
    )
    print(f"PREDICTIONS={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
