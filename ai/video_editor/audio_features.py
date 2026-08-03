"""Cheap frame-level audio features used by adaptive highlight selection."""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path
from typing import Any


def _percentile(values: Any, percentile: float) -> float:
    import numpy as np

    return float(np.percentile(values, percentile)) if len(values) else 0.0


def extract_audio_features(
    waveform: Any,
    *,
    sample_rate: int = 16_000,
    frame_ms: int = 500,
) -> list[dict[str, Any]]:
    """Return dBFS, level change, spectral flux, centroid, and ZCR windows."""

    import numpy as np

    samples = np.asarray(waveform, dtype=np.float32).reshape(-1)
    frame_size = max(1, round(sample_rate * frame_ms / 1000))
    window = np.hanning(frame_size).astype(np.float32)
    frequencies = np.fft.rfftfreq(frame_size, 1.0 / sample_rate)
    raw: list[dict[str, Any]] = []
    previous_spectrum = None
    previous_dbfs = None
    for start in range(0, len(samples), frame_size):
        frame = samples[start : start + frame_size]
        if not len(frame):
            continue
        if len(frame) < frame_size:
            frame = np.pad(frame, (0, frame_size - len(frame)))
        rms = float(np.sqrt(np.mean(np.square(frame, dtype=np.float64))))
        peak = float(np.max(np.abs(frame)))
        dbfs = 20.0 * math.log10(max(rms, 1e-8))
        peak_dbfs = 20.0 * math.log10(max(peak, 1e-8))
        zcr = float(np.mean(np.abs(np.diff(np.signbit(frame)))))
        spectrum = np.abs(np.fft.rfft(frame * window)).astype(np.float64)
        spectrum_sum = float(np.sum(spectrum))
        centroid_hz = (
            float(np.sum(frequencies * spectrum) / spectrum_sum)
            if spectrum_sum > 1e-12
            else 0.0
        )
        normalized = spectrum / max(float(np.linalg.norm(spectrum)), 1e-12)
        spectral_flux = (
            float(np.sqrt(np.mean(np.square(normalized - previous_spectrum))))
            if previous_spectrum is not None
            else 0.0
        )
        db_delta = dbfs - previous_dbfs if previous_dbfs is not None else 0.0
        end = min(len(samples), start + frame_size)
        raw.append(
            {
                "startMs": round(start / sample_rate * 1000),
                "endMs": round(end / sample_rate * 1000),
                "dbfs": round(dbfs, 4),
                "peakDbfs": round(peak_dbfs, 4),
                "dbDelta": round(db_delta, 4),
                "spectralFlux": round(spectral_flux, 8),
                "spectralCentroidHz": round(centroid_hz, 2),
                "zeroCrossingRate": round(zcr, 6),
            }
        )
        previous_spectrum = normalized
        previous_dbfs = dbfs

    db_values = [row["dbfs"] for row in raw]
    flux_values = [row["spectralFlux"] for row in raw]
    db_low = _percentile(db_values, 10)
    db_high = _percentile(db_values, 90)
    flux_high = max(_percentile(flux_values, 95), 1e-9)
    db_range = max(db_high - db_low, 1.0)
    for row in raw:
        row["relativeLoudness"] = round(
            max(0.0, min(1.0, (row["dbfs"] - db_low) / db_range)), 6
        )
        row["loudnessRise"] = round(
            max(0.0, min(1.0, row["dbDelta"] / 12.0)), 6
        )
        row["normalizedFlux"] = round(
            max(0.0, min(1.0, row["spectralFlux"] / flux_high)), 6
        )
    return raw


def analyze_video(video_path: Path) -> dict[str, Any]:
    from .yamnet_analysis import decode_mono_audio

    started = time.perf_counter()
    waveform = decode_mono_audio(video_path, 16_000)
    return {
        "analysisVersion": "audio-features-v1",
        "sourcePath": video_path.name,
        "durationMs": round(len(waveform) / 16_000 * 1000),
        "processingSeconds": round(time.perf_counter() - started, 3),
        "audioWindows": extract_audio_features(waveform),
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("videos", type=Path, nargs="+")
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for index, video_path in enumerate(args.videos, start=1):
        analysis = analyze_video(video_path)
        output_path = args.output_dir / f"{video_path.stem}.audio.json"
        output_path.write_text(
            json.dumps(analysis, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(
            f"[{index}/{len(args.videos)}] {analysis['processingSeconds']}s -> {output_path}",
            file=sys.stderr,
            flush=True,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
