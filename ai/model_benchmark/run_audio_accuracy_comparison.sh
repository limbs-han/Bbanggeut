#!/usr/bin/env bash
set -Eeuo pipefail

repo="${REPO_ROOT:-$HOME/william-james}"
dataset_root="${AUDIO_ACCURACY_DATASET:-$HOME/ai_datasets/model_benchmark/office-audio-events-v1}"
model_root="${AUDIO_BENCHMARK_MODEL_ROOT:-$HOME/ai_models/audio-benchmark}"
results_root="${AUDIO_RESULTS_ROOT:-$HOME/ai_benchmark_results}"
yamnet_python="${YAMNET_PYTHON:-$HOME/venvs/yamnet/bin/python}"
torch_python="${AUDIO_TORCH_PYTHON:-$HOME/venvs/yolo/bin/python}"
evaluation_python="${AUDIO_EVALUATION_PYTHON:-python3}"
repeat_count="${AUDIO_REPEAT_COUNT:-3}"
cooldown_seconds="${AUDIO_COOLDOWN_SECONDS:-30}"

prediction_runner="$repo/ai/model_benchmark/audio_prediction_runner.py"
accuracy_runner="$repo/ai/model_benchmark/audio_accuracy_runner.py"
dataset_tool="$repo/ai/model_benchmark/benchmark_dataset.py"
report_runner="$repo/ai/model_benchmark/audio_comparison_report.py"

efficientat_source="$model_root/sources/EfficientAT"
panns_source="$model_root/sources/audioset_tagging_cnn"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
comparison_id="audio-accuracy-comparison-$timestamp"
batch_dir="$results_root/$comparison_id"

models=(
  "YAMNet:yamnet-tflite:yamnet.tflite:yamnet_class_map.csv:-:tflite:yamnet"
  "EfficientAT MN10:efficientat-mn10:efficientat_mn10_as.pt:class_labels_indices.csv:EfficientAT:pytorch:efficientat-mn10"
  "PANNs CNN10:panns-cnn10:Cnn10_mAP=0.380.pth:class_labels_indices.csv:audioset_tagging_cnn:pytorch:panns-cnn10"
)

echo "=== PRECHECK ==="

test -f "$prediction_runner"
test -f "$accuracy_runner"
test -f "$dataset_tool"
test -f "$report_runner"
test -f "$dataset_root/dataset.json"
test ! -e "$batch_dir"

for value in "$repeat_count" "$cooldown_seconds"; do
  [[ "$value" =~ ^[0-9]+$ ]] || {
    echo "ERROR: repeat and cooldown values must be integers" >&2
    exit 1
  }
done
test "$repeat_count" -ge 1

if systemctl is-active --quiet wj-edge-ai-recording; then
  echo "ERROR: stop wj-edge-ai-recording before a fair GPU benchmark" >&2
  exit 1
fi

if systemctl is-active --quiet wj-device-agent; then
  echo "ERROR: stop wj-device-agent so app live streaming stays offline" >&2
  exit 1
fi

if systemctl is-active --quiet wj-local-recording; then
  echo "ERROR: stop wj-local-recording before a fair benchmark" >&2
  exit 1
fi

if systemctl is-active --quiet wj-servo-controller; then
  echo "ERROR: stop wj-servo-controller and turn the servo battery OFF" >&2
  exit 1
fi

if pgrep -af '[a]udio_prediction_runner.py|[a]udio_accuracy_runner.py'; then
  echo "ERROR: another audio benchmark process is active" >&2
  exit 1
fi

test -x "$yamnet_python"
test -x "$torch_python"
command -v "$evaluation_python" >/dev/null 2>&1 || test -x "$evaluation_python"

"$evaluation_python" "$dataset_tool" validate --dataset-root "$dataset_root"

"$evaluation_python" - "$dataset_root/dataset.json" <<'PY'
import json
from pathlib import Path
import sys

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
rows = [row for row in manifest.get("samples", []) if row.get("split") in {"validation", "test"}]

def positive(row, event_type):
    return event_type in {
        str(value).strip().lower() for value in row.get("labels", [])
    }

if any(row.get("review", {}).get("status") != "verified" for row in rows):
    raise SystemExit("ERROR: every validation/test sample must be verified")
if any(not row.get("sessionId") for row in rows):
    raise SystemExit("ERROR: every validation/test sample requires sessionId")
session_splits = {}
for row in rows:
    session_splits.setdefault(row["sessionId"], set()).add(row["split"])
leaked = sorted(session for session, splits in session_splits.items() if len(splits) > 1)
if leaked:
    raise SystemExit(f"ERROR: recording sessions cross splits: {', '.join(leaked[:8])}")
for split in ("validation", "test"):
    selected = [row for row in rows if row.get("split") == split]
    for event_type in ("laughter", "clap"):
        positives = sum(positive(row, event_type) for row in selected)
        negatives = len(selected) - positives
        print(
            f"SPLIT={split} EVENT={event_type} SAMPLES={len(selected)} "
            f"POSITIVE={positives} NEGATIVE={negatives}"
        )
        if positives < 10 or negatives < 10:
            raise SystemExit(
                f"ERROR: {split}/{event_type} requires at least 10 positive "
                "and 10 negative samples"
            )

test_rows = [row for row in rows if row.get("split") == "test"]
continuous = [
    row
    for row in test_rows
    if str(row.get("sampleId", "")).startswith("test-continuous-negative-")
]
external = [
    row
    for row in test_rows
    if "external-generalization" in row.get("conditions", [])
]
local_direct = [
    row
    for row in test_rows
    if row not in continuous and row not in external
]
print(
    f"TEST_COHORTS localDirect={len(local_direct)} "
    f"continuousNegative={len(continuous)} "
    f"externalGeneralization={len(external)}"
)
if len(local_direct) != 60:
    raise SystemExit("ERROR: localDirect test cohort must contain exactly 60 samples")
if len(continuous) != 4:
    raise SystemExit(
        "ERROR: continuousNegative test cohort must contain exactly 4 samples"
    )
if len(external) != 2000:
    raise SystemExit(
        "ERROR: externalGeneralization test cohort must contain exactly 2000 samples"
    )
PY

echo "=== MODEL AND SOURCE CHECKS ==="

test -f "$model_root/yamnet.tflite"
test -f "$model_root/efficientat_mn10_as.pt"
test -f "$model_root/Cnn10_mAP=0.380.pth"
test -f "$model_root/yamnet_class_map.csv"
test "$(git -C "$efficientat_source" rev-parse HEAD)" = \
  "a425fdce92572e602a1d5634799bd9f1f2efa806"
test "$(git -C "$panns_source" rev-parse HEAD)" = \
  "d2f4b8c18eab44737fcc0de1248ae21eb43f6aa4"

"$yamnet_python" - <<'PY'
import librosa
import numpy
try:
    import tflite_runtime  # noqa: F401
except ImportError:
    import tensorflow  # noqa: F401
print("PASS: YAMNet runtime dependencies")
PY

"$torch_python" - <<'PY'
import librosa
import numpy
import torch
import torchaudio
import torchlibrosa
if not torch.cuda.is_available():
    raise SystemExit("ERROR: CUDA is not available")
print(f"PASS: PyTorch audio dependencies device={torch.cuda.get_device_name(0)}")
PY

mkdir -p "$batch_dir"
echo "COMPARISON_ID=$comparison_id"
echo "RESULTS_DIR=$batch_dir"
echo "REPEAT_COUNT=$repeat_count"

total_runs=$((repeat_count * ${#models[@]}))
execution_order=0

for ((round_index = 0; round_index < repeat_count; round_index++)); do
  round_number=$((round_index + 1))
  printf -v round_slug '%02d' "$round_number"

  echo
  echo "=== ROUND $round_number/$repeat_count ==="

  for ((position = 0; position < ${#models[@]}; position++)); do
    model_index=$(((round_index + position) % ${#models[@]}))
    IFS=: read -r \
      model_name model_kind model_file class_map_file source_name runtime slug \
      <<<"${models[$model_index]}"
    run_dir="$batch_dir/round-$round_slug/$slug"
    prediction_file="$run_dir/predictions.jsonl"
    laughter_evaluation_dir="$run_dir/evaluation-laughter"
    clap_evaluation_dir="$run_dir/evaluation-clap"
    execution_order=$((execution_order + 1))

    model_path="$model_root/$model_file"
    class_map="$model_root/$class_map_file"
    source_repo=""
    python_bin="$torch_python"
    if test "$source_name" = "EfficientAT"; then
      source_repo="$efficientat_source"
      class_map="$source_repo/metadata/$class_map_file"
    elif test "$source_name" = "audioset_tagging_cnn"; then
      source_repo="$panns_source"
      class_map="$source_repo/metadata/$class_map_file"
    else
      python_bin="$yamnet_python"
    fi

    echo
    echo "=== RUN $execution_order/$total_runs: $model_name ==="

    prediction_command=(
      "$python_bin" -u "$prediction_runner"
      --dataset-root "$dataset_root"
      --model-kind "$model_kind"
      --model "$model_path"
      --model-name "$model_name"
      --class-map "$class_map"
      --output "$prediction_file"
      --split validation
      --split test
      --device cuda
      --window-seconds 0.975
      --hop-seconds 0.4875
      --warmup-windows 3
    )
    if test -n "$source_repo"; then
      prediction_command+=(--source-repo "$source_repo")
    fi
    "${prediction_command[@]}"

    for event_type in laughter clap; do
      evaluation_dir="$laughter_evaluation_dir"
      if test "$event_type" = "clap"; then
        evaluation_dir="$clap_evaluation_dir"
      fi

      "$evaluation_python" -u "$accuracy_runner" \
        --dataset-root "$dataset_root" \
        --predictions "$prediction_file" \
        --prediction-metadata "$run_dir/prediction-metadata.json" \
        --model-name "$model_name" \
        --runtime "$runtime" \
        --model "$model_path" \
        --event-type "$event_type" \
        --minimum-recall 0.85 \
        --required-consecutive-windows 2 \
        --cooldown-seconds 12 \
        --hop-seconds 0.4875 \
        --score-aggregation max \
        --comparison-id "$comparison_id" \
        --trial-index "$round_number" \
        --trial-count "$repeat_count" \
        --execution-order "$execution_order" \
        --output-dir "$evaluation_dir"
    done

    if ((execution_order < total_runs)); then
      echo "Cooling down for ${cooldown_seconds}s before the next model."
      sleep "$cooldown_seconds"
    fi
  done
done

"$evaluation_python" -u "$report_runner" \
  --results-dir "$batch_dir" \
  --output-dir "$batch_dir/report" \
  --expected-repeats "$repeat_count"

echo
echo "PASS: all repeated audio accuracy runs completed"
echo "RESULTS_DIR=$batch_dir"
