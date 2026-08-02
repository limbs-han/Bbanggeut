#!/usr/bin/env bash

set -Eeuo pipefail

repo="${REPO_ROOT:-$HOME/william-james}"
python_bin="${YOLO_PYTHON:-$HOME/venvs/yolo/bin/python}"
runner="$repo/ai/model_benchmark/vision_accuracy_runner.py"
dataset_root="${YOLO_ACCURACY_DATASET:-$HOME/ai_datasets/model_benchmark/office-vision-gt-v1/exports/yolo-person-test-406}"
model_root="${YOLO_MODEL_ROOT:-$HOME/ai_models/yolo-detect-pt}"
results_root="${YOLO_RESULTS_ROOT:-$HOME/ai_benchmark_results}"
cooldown_seconds="${YOLO_COOLDOWN_SECONDS:-30}"
repeat_count="${YOLO_REPEAT_COUNT:-3}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
comparison_id="yolo-accuracy-comparison-$timestamp"
batch_dir="$results_root/$comparison_id"

models=(
  "YOLOv8n:yolov8n.pt:yolov8n"
  "YOLO11n:yolo11n.pt:yolo11n"
  "YOLO26n:yolo26n.pt:yolo26n"
)

echo "=== PRECHECK ==="

test -x "$python_bin"
test -f "$runner"
test -d "$dataset_root/images/test"
test -d "$dataset_root/labels/test"
test ! -e "$batch_dir"

if ! [[ "$repeat_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: YOLO_REPEAT_COUNT must be a positive integer" >&2
  exit 1
fi

if pgrep -af '[v]ision_accuracy_runner.py'; then
  echo "ERROR: another accuracy runner is already active" >&2
  exit 1
fi

if systemctl is-active --quiet wj-edge-ai-recording; then
  echo "ERROR: stop wj-edge-ai-recording before a fair GPU benchmark" >&2
  exit 1
fi

for model in "${models[@]}"; do
  IFS=: read -r _ filename _ <<<"$model"
  test -f "$model_root/$filename"
done

image_count="$({
  find "$dataset_root/images/test" -maxdepth 1 -type f \
    \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' \)
} | wc -l)"
label_count="$(
  find "$dataset_root/labels/test" -maxdepth 1 -type f -name '*.txt' |
    wc -l
)"
box_count="$(
  awk 'NF { count++ } END { print count + 0 }' \
    "$dataset_root"/labels/test/*.txt
)"

printf 'IMAGES=%s\nLABELS=%s\nBOXES=%s\n' \
  "$image_count" "$label_count" "$box_count"

if [[ "$image_count" != 406 || "$label_count" != 406 || "$box_count" != 597 ]]; then
  echo "ERROR: expected the verified 406-image, 597-box dataset" >&2
  exit 1
fi

mkdir -p "$batch_dir"
echo "BATCH_DIR=$batch_dir"
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
    IFS=: read -r model_name filename slug <<<"${models[$model_index]}"
    output_dir="$batch_dir/round-$round_slug/$slug"
    execution_order=$((execution_order + 1))

    echo
    echo "=== RUN $execution_order/$total_runs: $model_name (round $round_number) ==="

    "$python_bin" -u "$runner" \
      --dataset-root "$dataset_root" \
      --model "$model_root/$filename" \
      --model-name "$model_name" \
      --output-dir "$output_dir" \
      --device 0 \
      --imgsz 640 \
      --batch 1 \
      --warmup-frames 10 \
      --map-confidence 0.001 \
      --operating-confidence 0.25 \
      --nms-iou 0.7 \
      --match-iou 0.5 \
      --class-id 0 \
      --comparison-id "$comparison_id" \
      --trial-index "$round_number" \
      --trial-count "$repeat_count" \
      --execution-order "$execution_order"

    if ((execution_order < total_runs)); then
      echo "Cooling down for ${cooldown_seconds}s before the next model."
      sleep "$cooldown_seconds"
    fi
  done
done

echo
echo "PASS: three-model repeated accuracy comparison completed"
echo "RESULTS_DIR=$batch_dir"
