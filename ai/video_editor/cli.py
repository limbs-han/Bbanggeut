"""Command-line adapter from analysis JSON to an initial edit recipe."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from .cut_selector import select_cut
from .models import ScoreSegment, SelectorConfig


def build_recipe(payload: dict[str, Any]) -> dict[str, Any]:
    duration_ms = int(payload["durationMs"])
    anchor_ms = payload.get("anchorMs")
    anchor_start = payload.get("anchorStartMs", anchor_ms)
    anchor_end = payload.get("anchorEndMs", anchor_ms)
    if anchor_start is None or anchor_end is None:
        raise ValueError("anchorMs or both anchorStartMs/anchorEndMs are required")
    anchor_start_ms = int(anchor_start)
    anchor_end_ms = int(anchor_end)
    config_payload = payload.get("selectorConfig", {})
    config = SelectorConfig(
        min_duration_ms=int(config_payload.get("minDurationMs", 45_000)),
        max_duration_ms=int(config_payload.get("maxDurationMs", 65_000)),
        context_before_ms=int(config_payload.get("contextBeforeMs", 10_000)),
        context_after_ms=int(config_payload.get("contextAfterMs", 10_000)),
    )
    selection = select_cut(
        duration_ms=duration_ms,
        anchor_start_ms=anchor_start_ms,
        anchor_end_ms=anchor_end_ms,
        segments=[ScoreSegment.from_dict(value) for value in payload.get("segments", [])],
        config=config,
    )
    return {
        "recipeVersion": "v1",
        "sourceVideoId": payload.get("sourceVideoId"),
        "analysisVersion": payload.get("analysisVersion", "v1"),
        "revision": 1,
        "cut": selection.to_dict(),
        "zoomSegments": [],
        "arLayers": [],
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("analysis_json", type=Path)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    payload = json.loads(args.analysis_json.read_text(encoding="utf-8"))
    output = json.dumps(build_recipe(payload), ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(output, encoding="utf-8")
    else:
        sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
