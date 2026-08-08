"""Build an adaptive v2 edit recipe from reusable analysis JSON files."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from .adaptive_selector import build_timeline, select_adaptive_highlight
from .duration_presets import apply_duration_preset
from .face_tracks import build_face_tracks
from .zoom_planner import plan_zoom_segments


def build_adaptive_recipe(
    yamnet_analysis: dict[str, Any],
    audio_analysis: dict[str, Any],
    video_analysis: dict[str, Any] | None = None,
    expression_analysis: dict[str, Any] | None = None,
    *,
    duration_preset: str = "auto",
    zoom_enabled: bool = False,
) -> dict[str, Any]:
    timeline = build_timeline(yamnet_analysis, audio_analysis, video_analysis)
    adaptive_cut = select_adaptive_highlight(
        timeline, yamnet_analysis, video_analysis
    )
    cut = apply_duration_preset(
        adaptive_cut,
        timeline,
        yamnet_analysis,
        video_analysis,
        duration_preset,
    )
    # 사람별 얼굴 궤적. 자동 줌이 "누구를 따라갈지" 고르는 데 쓰고, 레시피에도
    # 실어 보낸다 — 앱의 얼굴 추적 스티커가 같은 목록에서 사람을 고른다.
    face_tracks = (
        build_face_tracks(expression_analysis) if expression_analysis else []
    )
    zoom_segments = plan_zoom_segments(
        timeline,
        expression_analysis,
        cut,
        enabled=zoom_enabled,
        face_tracks=face_tracks,
    )
    return {
        "recipeVersion": (
            "v10"
            if expression_analysis and zoom_enabled
            else (
                "v4"
                if video_analysis and (duration_preset != "auto" or zoom_enabled)
                else ("v3" if video_analysis else "v2")
            )
        ),
        "sourcePath": yamnet_analysis.get("sourcePath"),
        "analysisVersions": {
            "yamnet": yamnet_analysis.get("analysisVersion"),
            "audio": audio_analysis.get("analysisVersion"),
            "video": video_analysis.get("analysisVersion") if video_analysis else None,
            "expression": (
                expression_analysis.get("analysisVersion")
                if expression_analysis
                else None
            ),
        },
        "revision": 1,
        "cut": cut,
        "durationPreset": duration_preset,
        "zoomEnabled": zoom_enabled,
        "zoomSegments": zoom_segments,
        "faceTracks": face_tracks,
        "arLayers": [],
        "scoreTimeline": timeline,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--yamnet", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--video", type=Path)
    parser.add_argument("--expression", type=Path)
    parser.add_argument(
        "--duration-preset",
        choices=("auto", "short", "medium", "long"),
        default="auto",
    )
    parser.add_argument("--zoom", choices=("on", "off"), default="off")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    recipe = build_adaptive_recipe(
        json.loads(args.yamnet.read_text(encoding="utf-8")),
        json.loads(args.audio.read_text(encoding="utf-8")),
        json.loads(args.video.read_text(encoding="utf-8")) if args.video else None,
        json.loads(args.expression.read_text(encoding="utf-8"))
        if args.expression
        else None,
        duration_preset=args.duration_preset,
        zoom_enabled=args.zoom == "on",
    )
    output = json.dumps(recipe, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
    else:
        sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
