"""Generate reusable YAMNet audio-event windows with MediaPipe Tasks.

Runtime dependencies are intentionally optional: ``mediapipe``, ``av``, and
``numpy`` are only required by this adapter, not by the cut-selection core.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any


LAUGHTER_KEYWORDS = (
    "laughter",
    "laugh",
    "giggle",
    "snicker",
    "chuckle",
    "chortle",
)


def is_laughter_category(name: str) -> bool:
    normalized = name.casefold()
    return any(keyword in normalized for keyword in LAUGHTER_KEYWORDS)


def is_speech_category(name: str) -> bool:
    normalized = name.casefold()
    return "speech" in normalized or normalized in {"conversation", "narration, monologue"}


def is_music_category(name: str) -> bool:
    normalized = name.casefold()
    return "music" in normalized or normalized in {"singing", "choir"}


def is_reaction_category(name: str) -> bool:
    normalized = name.casefold()
    return any(
        keyword in normalized
        for keyword in ("applause", "clapping", "cheering", "shout", "scream", "gasp")
    )


def decode_mono_audio(video_path: Path, sample_rate: int = 16_000) -> Any:
    import av
    import numpy as np

    chunks = []
    resampler = av.AudioResampler(format="fltp", layout="mono", rate=sample_rate)
    with av.open(str(video_path)) as container:
        for frame in container.decode(audio=0):
            for output_frame in resampler.resample(frame):
                chunks.append(output_frame.to_ndarray().reshape(-1))
        for output_frame in resampler.resample(None):
            chunks.append(output_frame.to_ndarray().reshape(-1))
    if not chunks:
        raise ValueError(f"video contains no decodable audio: {video_path}")
    return np.concatenate(chunks).astype(np.float32)


def classify_video(video_path: Path, model_path: Path) -> dict[str, Any]:
    from mediapipe.tasks import python
    from mediapipe.tasks.python import audio
    from mediapipe.tasks.python.components import containers

    sample_rate = 16_000
    waveform = decode_mono_audio(video_path, sample_rate)
    options = audio.AudioClassifierOptions(
        base_options=python.BaseOptions(model_asset_path=str(model_path)),
        max_results=521,
    )
    started = time.perf_counter()
    windows = []
    with audio.AudioClassifier.create_from_options(options) as classifier:
        results = classifier.classify(
            containers.AudioData.create_from_array(waveform, sample_rate)
        )
    for result in results:
        categories = result.classifications[0].categories
        laughter = [
            category
            for category in categories
            if is_laughter_category(category.category_name or "")
        ]
        best = max(laughter, key=lambda category: category.score, default=None)
        speech_score = max(
            (
                category.score
                for category in categories
                if is_speech_category(category.category_name or "")
            ),
            default=0.0,
        )
        silence_score = max(
            (
                category.score
                for category in categories
                if (category.category_name or "").casefold() == "silence"
            ),
            default=0.0,
        )
        music_score = max(
            (
                category.score
                for category in categories
                if is_music_category(category.category_name or "")
            ),
            default=0.0,
        )
        reaction_score = max(
            (
                category.score
                for category in categories
                if is_reaction_category(category.category_name or "")
            ),
            default=0.0,
        )
        top_categories = sorted(categories, key=lambda category: category.score, reverse=True)[:8]
        start_ms = int(result.timestamp_ms)
        windows.append(
            {
                "startMs": start_ms,
                "endMs": min(
                    round(len(waveform) / sample_rate * 1000), start_ms + 975
                ),
                "laughterScore": round(best.score, 6) if best else 0.0,
                "laughterLabel": best.category_name if best else None,
                "speechScore": round(speech_score, 6),
                "silenceScore": round(silence_score, 6),
                "musicScore": round(music_score, 6),
                "reactionScore": round(reaction_score, 6),
                "topCategories": [
                    {
                        "name": category.category_name,
                        "score": round(category.score, 6),
                    }
                    for category in top_categories
                ],
            }
        )
    return {
        "analysisVersion": "yamnet-mediapipe-v1",
        "sourcePath": video_path.name,
        "durationMs": round(len(waveform) / sample_rate * 1000),
        "processingSeconds": round(time.perf_counter() - started, 3),
        "yamnetWindows": windows,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("videos", type=Path, nargs="+")
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for index, video_path in enumerate(args.videos, start=1):
        print(
            f"[{index}/{len(args.videos)}] classifying {video_path.name}",
            file=sys.stderr,
            flush=True,
        )
        analysis = classify_video(video_path, args.model)
        output_path = args.output_dir / f"{video_path.stem}.yamnet.json"
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
