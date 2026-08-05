#!/usr/bin/env python3
"""Review YAMNet and EfficientAT shadow detections interactively.

The reviewer tails diagnostics produced by the two detectors, correlates the
same event type within a bounded time window, and asks a human whether the
detected situation actually occurred.  It only reads detector logs and writes
local review JSONL.  It has no trigger, MQTT, API, or upload capability.
"""

from __future__ import annotations

import argparse
from collections import Counter, deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
import os
from pathlib import Path
from queue import Empty, Queue
import sys
import threading
import time
from typing import Any, Callable
import uuid


SCHEMA_VERSION = "0.1"
EVENT_TYPES = ("LAUGHTER", "CLAP")
MODEL_NAMES = ("YAMNet", "EfficientAT MN10")


def utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def parse_timestamp(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError(f"timestamp must include a timezone: {value}")
    return parsed


@dataclass(frozen=True)
class Detection:
    source: str
    event_type: str
    detected_at: str
    confidence: float | None
    class_name: str | None
    source_record: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "eventType": self.event_type,
            "detectedAt": self.detected_at,
            "confidence": self.confidence,
            "className": self.class_name,
            "sourceRecord": self.source_record,
        }


def detections_from_yamnet(row: dict[str, Any]) -> list[Detection]:
    detected_at = row.get("observedAt")
    if not isinstance(detected_at, str):
        return []
    detections: list[Detection] = []
    if row.get("wouldTrigger") is True:
        detections.append(
            Detection(
                source="YAMNet",
                event_type="LAUGHTER",
                detected_at=detected_at,
                confidence=number_or_none(row.get("selectedScore")),
                class_name=string_or_none(row.get("selectedClass")),
            )
        )
    if row.get("clapWouldTrigger") is True:
        detections.append(
            Detection(
                source="YAMNet",
                event_type="CLAP",
                detected_at=detected_at,
                confidence=number_or_none(row.get("clapScore")),
                class_name=string_or_none(row.get("clapClass")),
            )
        )
    return detections


def detections_from_shadow(row: dict[str, Any]) -> list[Detection]:
    detected_at = row.get("detectedAt", row.get("observedAt"))
    event_type = row.get("eventType")
    if (
        row.get("recordType") != "virtual-event"
        or event_type not in EVENT_TYPES
        or not isinstance(detected_at, str)
    ):
        return []
    return [
        Detection(
            source="EfficientAT MN10",
            event_type=event_type,
            detected_at=detected_at,
            confidence=number_or_none(row.get("confidence")),
            class_name=string_or_none(row.get("className")),
            source_record=string_or_none(row.get("virtualEventId")),
        )
    ]


def number_or_none(value: Any) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


def string_or_none(value: Any) -> str | None:
    return value if isinstance(value, str) else None


class JsonlFollower:
    """Read complete newly appended JSONL records without losing partial rows."""

    def __init__(
        self,
        path: Path,
        parser: Callable[[dict[str, Any]], list[Detection]],
        *,
        start_at_end: bool,
    ) -> None:
        self.path = path
        self.parser = parser
        self.start_at_end = start_at_end
        self.initialized = False
        self.offset = 0
        self.partial = b""

    def poll(self) -> list[Detection]:
        if not self.initialized:
            self.initialized = True
            if self.start_at_end and self.path.is_file():
                self.offset = self.path.stat().st_size
                return []
        if not self.path.is_file():
            return []
        size = self.path.stat().st_size
        if size < self.offset:
            self.offset = 0
            self.partial = b""
        with self.path.open("rb") as source:
            source.seek(self.offset)
            chunk = source.read()
            self.offset = source.tell()
        if not chunk:
            return []
        rows = self.partial + chunk
        parts = rows.split(b"\n")
        self.partial = parts.pop()
        detections: list[Detection] = []
        for raw_line in parts:
            if not raw_line.strip():
                continue
            try:
                payload = json.loads(raw_line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise ValueError(f"invalid JSONL record in {self.path}") from error
            if isinstance(payload, dict):
                detections.extend(self.parser(payload))
        return detections


@dataclass
class ReviewCandidate:
    event_type: str
    first_arrived_monotonic: float
    detections: list[Detection] = field(default_factory=list)
    candidate_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    prompted: bool = False

    @property
    def detected_sources(self) -> set[str]:
        return {detection.source for detection in self.detections}


class CorrelationBuffer:
    def __init__(self, tolerance_seconds: float) -> None:
        if tolerance_seconds < 0:
            raise ValueError("tolerance seconds cannot be negative")
        self.tolerance_seconds = tolerance_seconds
        self.candidates: list[ReviewCandidate] = []

    def add(self, detection: Detection, now: float) -> ReviewCandidate:
        detected_at = parse_timestamp(detection.detected_at)
        matching: list[tuple[float, ReviewCandidate]] = []
        for candidate in self.candidates:
            if candidate.event_type != detection.event_type:
                continue
            gaps = [
                abs(
                    (
                        parse_timestamp(existing.detected_at) - detected_at
                    ).total_seconds()
                )
                for existing in candidate.detections
            ]
            gap = min(gaps) if gaps else float("inf")
            if gap <= self.tolerance_seconds:
                matching.append((gap, candidate))
        if matching:
            candidate = min(matching, key=lambda row: row[0])[1]
        else:
            candidate = ReviewCandidate(
                event_type=detection.event_type,
                first_arrived_monotonic=now,
            )
            self.candidates.append(candidate)
        candidate.detections.append(detection)
        return candidate

    def ready(self, now: float) -> list[ReviewCandidate]:
        ready = [
            candidate
            for candidate in self.candidates
            if not candidate.prompted
            and now - candidate.first_arrived_monotonic
            >= self.tolerance_seconds
        ]
        for candidate in ready:
            candidate.prompted = True
        return ready

    def complete(self, candidate: ReviewCandidate) -> None:
        self.candidates.remove(candidate)


def model_outcomes(
    detections: list[Detection],
    actual_event: bool,
) -> dict[str, str]:
    detected = {detection.source for detection in detections}
    outcomes: dict[str, str] = {}
    for model in MODEL_NAMES:
        if model in detected:
            outcomes[model] = "TP" if actual_event else "FP"
        else:
            outcomes[model] = "FN" if actual_event else "TN"
    return outcomes


def agreement_name(detections: list[Detection]) -> str:
    sources = {detection.source for detection in detections}
    if sources == set(MODEL_NAMES):
        return "both"
    if sources == {"YAMNet"}:
        return "yamnet-only"
    if sources == {"EfficientAT MN10"}:
        return "efficientat-only"
    if not sources:
        return "neither-manual-miss"
    return "other"


def build_review_record(
    candidate: ReviewCandidate,
    answer: str,
) -> dict[str, Any]:
    normalized = answer.strip().upper()
    if normalized not in {"YES", "NO", "SKIP"}:
        raise ValueError("answer must be YES, NO, or SKIP")
    actual_event = None if normalized == "SKIP" else normalized == "YES"
    return {
        "schemaVersion": SCHEMA_VERSION,
        "recordType": "manual-review",
        "reviewId": str(uuid.uuid4()),
        "candidateId": candidate.candidate_id,
        "reviewedAt": utc_now(),
        "eventType": candidate.event_type,
        "answer": normalized,
        "actualEvent": actual_event,
        "agreement": agreement_name(candidate.detections),
        "detectedBy": sorted(candidate.detected_sources),
        "detections": [
            detection.to_dict() for detection in candidate.detections
        ],
        "modelOutcomes": (
            model_outcomes(candidate.detections, actual_event)
            if actual_event is not None
            else {model: "UNREVIEWED" for model in MODEL_NAMES}
        ),
        "operationalAuthority": False,
    }


def build_manual_miss_record(event_type: str) -> dict[str, Any]:
    if event_type not in EVENT_TYPES:
        raise ValueError(f"unsupported missed event type: {event_type}")
    candidate = ReviewCandidate(
        event_type=event_type,
        first_arrived_monotonic=time.monotonic(),
    )
    record = build_review_record(candidate, "YES")
    record["recordType"] = "manual-miss"
    record["manualMissAt"] = record["reviewedAt"]
    return record


class DurableJsonlWriter:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.output = path.open("a", encoding="utf-8", buffering=1)

    def write(self, payload: dict[str, Any]) -> None:
        self.output.write(
            json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
            + "\n"
        )
        self.output.flush()
        os.fsync(self.output.fileno())

    def close(self) -> None:
        self.output.close()


class ReviewRecorder:
    def __init__(self, writer: DurableJsonlWriter) -> None:
        self.writer = writer
        self.answer_counts: Counter[str] = Counter()
        self.outcome_counts: dict[str, Counter[str]] = {
            model: Counter() for model in MODEL_NAMES
        }
        self.review_count = 0

    def record(self, payload: dict[str, Any]) -> None:
        self.writer.write(payload)
        self.review_count += 1
        self.answer_counts[str(payload["answer"])] += 1
        for model, outcome in payload["modelOutcomes"].items():
            self.outcome_counts[model][outcome] += 1

    def summary(self, reason: str, unreviewed_count: int) -> dict[str, Any]:
        return {
            "schemaVersion": SCHEMA_VERSION,
            "recordType": "session-summary",
            "stoppedAt": utc_now(),
            "reason": reason,
            "reviewCount": self.review_count,
            "answerCounts": dict(sorted(self.answer_counts.items())),
            "modelOutcomes": {
                model: dict(sorted(counts.items()))
                for model, counts in self.outcome_counts.items()
            },
            "unreviewedCandidateCount": unreviewed_count,
            "operationalAuthority": False,
        }


@dataclass(frozen=True)
class TailerFailure:
    detail: str


def follow_logs(
    followers: list[JsonlFollower],
    output_queue: Queue[Detection | TailerFailure],
    stop: threading.Event,
    poll_seconds: float,
) -> None:
    try:
        while not stop.is_set():
            for follower in followers:
                for detection in follower.poll():
                    output_queue.put(detection)
            stop.wait(poll_seconds)
    except BaseException as error:
        output_queue.put(TailerFailure(f"{type(error).__name__}: {error}"))
        stop.set()


def read_commands(command_queue: Queue[str], stop: threading.Event) -> None:
    while not stop.is_set():
        line = sys.stdin.readline()
        if line == "":
            command_queue.put("__EOF__")
            return
        command_queue.put(line.strip())


def detection_line(detection: Detection) -> str:
    score = (
        f"{detection.confidence:.6f}"
        if detection.confidence is not None
        else "N/A"
    )
    class_name = detection.class_name or "N/A"
    return (
        f"{detection.source} | {detection.event_type} | "
        f"score={score} | class={class_name} | {detection.detected_at}"
    )


def print_candidate_prompt(candidate: ReviewCandidate) -> None:
    print("\n" + "=" * 72)
    print(f"검수 대상: {candidate.event_type}")
    for detection in candidate.detections:
        print(f"  - {detection_line(detection)}")
    missing = set(MODEL_NAMES) - candidate.detected_sources
    if missing:
        print(f"  - 감지하지 않은 모델: {', '.join(sorted(missing))}")
    print(
        f"실제로 {candidate.event_type} 상황이 맞았나요? "
        "YES 또는 NO 입력 (보류는 SKIP):"
    )
    print("> ", end="", flush=True)


def parse_miss_command(command: str) -> list[str] | None:
    normalized = " ".join(command.strip().upper().split())
    if normalized == "MISS LAUGHTER":
        return ["LAUGHTER"]
    if normalized == "MISS CLAP":
        return ["CLAP"]
    if normalized == "MISS BOTH":
        return ["LAUGHTER", "CLAP"]
    return None


def print_summary(summary: dict[str, Any], output_path: Path) -> None:
    print("\n=== SHADOW MANUAL REVIEW SUMMARY ===")
    print(f"REVIEW_COUNT={summary['reviewCount']}")
    print(f"ANSWER_COUNTS={summary['answerCounts']}")
    for model, outcomes in summary["modelOutcomes"].items():
        print(f"{model}={outcomes}")
    print(
        "UNREVIEWED_CANDIDATES="
        f"{summary['unreviewedCandidateCount']}"
    )
    print(f"OUTPUT_JSONL={output_path}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--yamnet-diagnostics", type=Path, required=True)
    parser.add_argument("--shadow-diagnostics", type=Path, required=True)
    parser.add_argument("--output-jsonl", type=Path)
    parser.add_argument(
        "--match-tolerance-seconds",
        type=float,
        default=12.0,
    )
    parser.add_argument("--poll-seconds", type=float, default=0.25)
    parser.add_argument(
        "--start-from-beginning",
        action="store_true",
        help="Review existing records instead of following new records only.",
    )
    parser.add_argument("--no-bell", action="store_true")
    return parser.parse_args(argv)


def validate_args(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    yamnet_path = args.yamnet_diagnostics.expanduser().resolve()
    shadow_path = args.shadow_diagnostics.expanduser().resolve()
    output_path = (
        args.output_jsonl.expanduser().resolve()
        if args.output_jsonl is not None
        else yamnet_path.parent / "audio_shadow_manual_review.jsonl"
    )
    if args.match_tolerance_seconds < 0:
        raise SystemExit("--match-tolerance-seconds cannot be negative")
    if args.poll_seconds <= 0:
        raise SystemExit("--poll-seconds must be positive")
    if output_path in {yamnet_path, shadow_path}:
        raise SystemExit("review output must differ from detector diagnostics")
    return yamnet_path, shadow_path, output_path


def run(args: argparse.Namespace) -> int:
    yamnet_path, shadow_path, output_path = validate_args(args)
    stop = threading.Event()
    detection_queue: Queue[Detection | TailerFailure] = Queue()
    command_queue: Queue[str] = Queue()
    followers = [
        JsonlFollower(
            yamnet_path,
            detections_from_yamnet,
            start_at_end=not args.start_from_beginning,
        ),
        JsonlFollower(
            shadow_path,
            detections_from_shadow,
            start_at_end=not args.start_from_beginning,
        ),
    ]
    producer = threading.Thread(
        target=follow_logs,
        args=(followers, detection_queue, stop, args.poll_seconds),
        name="audio-shadow-log-follower",
        daemon=True,
    )
    input_reader = threading.Thread(
        target=read_commands,
        args=(command_queue, stop),
        name="audio-shadow-command-reader",
        daemon=True,
    )
    writer = DurableJsonlWriter(output_path)
    recorder = ReviewRecorder(writer)
    correlation = CorrelationBuffer(args.match_tolerance_seconds)
    ready_candidates: deque[ReviewCandidate] = deque()
    active_candidate: ReviewCandidate | None = None
    reason = "completed"
    writer.write(
        {
            "schemaVersion": SCHEMA_VERSION,
            "recordType": "session-start",
            "startedAt": utc_now(),
            "mode": "interactive-shadow-review",
            "yamnetDiagnostics": str(yamnet_path),
            "shadowDiagnostics": str(shadow_path),
            "startFromBeginning": args.start_from_beginning,
            "matchToleranceSeconds": args.match_tolerance_seconds,
            "operationalAuthority": False,
            "sideEffects": {
                "trigger": False,
                "mqtt": False,
                "upload": False,
                "api": False,
            },
        }
    )
    print("=== YAMNet / EfficientAT LIVE SHADOW REVIEW ===")
    print("새 감지가 생기면 모델별 결과를 표시한 뒤 YES/NO를 묻습니다.")
    print("두 모델이 모두 놓친 실제 이벤트는 아래처럼 입력하세요.")
    print("  MISS LAUGHTER")
    print("  MISS CLAP")
    print("  MISS BOTH")
    print("종료하려면 Ctrl+C를 누르세요.")
    print(f"REVIEW_OUTPUT={output_path}")
    print("WAITING_FOR_DETECTIONS=true")
    producer.start()
    input_reader.start()
    try:
        while True:
            while True:
                try:
                    item = detection_queue.get_nowait()
                except Empty:
                    break
                if isinstance(item, TailerFailure):
                    raise RuntimeError(f"log follower failed: {item.detail}")
                candidate = correlation.add(item, time.monotonic())
                if not args.no_bell:
                    print("\a", end="", flush=True)
                print(f"\n[감지] {detection_line(item)}")
                if candidate.prompted:
                    print(
                        "[추가 감지] 현재 검수 묶음에 같은 상황으로 "
                        "추가했습니다."
                    )

            ready_candidates.extend(correlation.ready(time.monotonic()))
            if active_candidate is None and ready_candidates:
                active_candidate = ready_candidates.popleft()
                print_candidate_prompt(active_candidate)

            try:
                command = command_queue.get(timeout=args.poll_seconds)
            except Empty:
                continue
            if command == "__EOF__":
                reason = "stdin-closed"
                break
            if not command:
                continue
            if active_candidate is not None:
                normalized = command.upper()
                if normalized not in {"YES", "NO", "SKIP"}:
                    print("현재 검수에는 YES, NO 또는 SKIP을 입력하세요.")
                    print("> ", end="", flush=True)
                    continue
                record = build_review_record(active_candidate, normalized)
                recorder.record(record)
                print(
                    f"RECORDED={normalized} "
                    f"EVENT={active_candidate.event_type} "
                    f"MODELS={sorted(active_candidate.detected_sources)}"
                )
                correlation.complete(active_candidate)
                active_candidate = None
                continue
            missed_types = parse_miss_command(command)
            if missed_types is None:
                print(
                    "대기 중에는 MISS LAUGHTER, MISS CLAP 또는 "
                    "MISS BOTH만 입력할 수 있습니다."
                )
                continue
            if correlation.candidates:
                print(
                    "현재 감지 결과의 상관관계를 기다리고 있습니다. "
                    "검수를 마친 뒤 MISS 명령을 입력하세요."
                )
                continue
            for event_type in missed_types:
                record = build_manual_miss_record(event_type)
                recorder.record(record)
                print(
                    f"RECORDED=MANUAL_MISS EVENT={event_type} "
                    "MODELS=[]"
                )
    except KeyboardInterrupt:
        reason = "keyboard-interrupt"
        print("\nCtrl+C received. Finishing the review safely.")
    except BaseException:
        reason = "error"
        raise
    finally:
        stop.set()
        producer.join(timeout=2.0)
        unreviewed_count = len(correlation.candidates)
        summary = recorder.summary(reason, unreviewed_count)
        writer.write(summary)
        writer.close()
        print_summary(summary, output_path)
    return 0


def main(argv: list[str] | None = None) -> int:
    return run(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())
