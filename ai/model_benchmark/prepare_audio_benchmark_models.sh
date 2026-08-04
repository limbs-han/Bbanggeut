#!/usr/bin/env bash
set -Eeuo pipefail

repo="${WJ_REPOSITORY:-$HOME/william-james}"
model_root="${AUDIO_BENCHMARK_MODEL_ROOT:-$HOME/ai_models/audio-benchmark}"
source_root="$model_root/sources"

efficientat_commit="a425fdce92572e602a1d5634799bd9f1f2efa806"
panns_commit="d2f4b8c18eab44737fcc0de1248ae21eb43f6aa4"

yamnet_sha256="10c95ea3eb9a7bb4cb8bddf6feb023250381008177ac162ce169694d05c317de"
efficientat_sha256="0bd7dc2443af498c289a2e739f02ebb515d6aa3fd3ab9db539c86123ae368a4e"
yamnet_class_map_sha256="cdf24d193e196d9e95912a2667051ae203e92a2ba09449218ccb40ef787c6df2"
audioset_class_map_sha256="cdd1049833c4b86127c2773ac0d14a2754b6a6d0d1798002ed5c66e699708429"
panns_md5="bfb1f1f9968938fa8ef4012b8471f5f6"

yamnet_source="$repo/ai/model_benchmark/models/yamnet.tflite"
efficientat_source="$repo/ai/model_benchmark/models/efficientat_mn10_as.pt"
yamnet_target="$model_root/yamnet.tflite"
efficientat_target="$model_root/efficientat_mn10_as.pt"
panns_target="$model_root/Cnn10_mAP=0.380.pth"
yamnet_class_map="$model_root/yamnet_class_map.csv"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command is missing: $1" >&2
    exit 1
  }
}

verify_sha256() {
  file="$1"
  expected="$2"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  echo "SHA256 file=$file expected=$expected actual=$actual"
  test "$actual" = "$expected"
}

prepare_source_repository() {
  name="$1"
  url="$2"
  commit="$3"
  target="$source_root/$name"

  if test -d "$target/.git"; then
    actual="$(git -C "$target" rev-parse HEAD)"
    test "$actual" = "$commit" || {
      echo "ERROR: $name source commit mismatch: $actual" >&2
      exit 1
    }
  elif test -e "$target"; then
    echo "ERROR: source target exists but is not a Git repository: $target" >&2
    exit 1
  else
    mkdir -p "$target"
    git -C "$target" init --quiet
    git -C "$target" remote add origin "$url"
    git -C "$target" fetch --quiet --depth 1 origin "$commit"
    git -C "$target" checkout --quiet --detach FETCH_HEAD
  fi

  echo "SOURCE name=$name commit=$(git -C "$target" rev-parse HEAD) path=$target"
}

for command_name in curl git install md5sum sha256sum; do
  require_command "$command_name"
done

echo "=== LOCAL MODEL ARTIFACTS ==="
test -f "$yamnet_source"
test -f "$efficientat_source"
verify_sha256 "$yamnet_source" "$yamnet_sha256"
verify_sha256 "$efficientat_source" "$efficientat_sha256"

mkdir -p "$model_root" "$source_root"
install -m 0644 "$yamnet_source" "$yamnet_target"
install -m 0644 "$efficientat_source" "$efficientat_target"

echo "=== PIN OFFICIAL SOURCE REPOSITORIES ==="
prepare_source_repository \
  EfficientAT \
  https://github.com/fschmid56/EfficientAT.git \
  "$efficientat_commit"
prepare_source_repository \
  audioset_tagging_cnn \
  https://github.com/qiuqiangkong/audioset_tagging_cnn.git \
  "$panns_commit"
verify_sha256 \
  "$source_root/EfficientAT/metadata/class_labels_indices.csv" \
  "$audioset_class_map_sha256"
verify_sha256 \
  "$source_root/audioset_tagging_cnn/metadata/class_labels_indices.csv" \
  "$audioset_class_map_sha256"

echo "=== YAMNET CLASS MAP ==="
if ! test -f "$yamnet_class_map"; then
  curl \
    --fail \
    --location \
    --retry 3 \
    --output "$yamnet_class_map.tmp" \
    https://raw.githubusercontent.com/tensorflow/models/master/research/audioset/yamnet/yamnet_class_map.csv
  mv "$yamnet_class_map.tmp" "$yamnet_class_map"
fi
verify_sha256 "$yamnet_class_map" "$yamnet_class_map_sha256"

echo "=== PANNS CNN10 CHECKPOINT ==="
if ! test -f "$panns_target"; then
  curl \
    --fail \
    --location \
    --retry 5 \
    --retry-delay 5 \
    --output "$panns_target.tmp" \
    'https://zenodo.org/records/3987831/files/Cnn10_mAP%3D0.380.pth?download=1'
  mv "$panns_target.tmp" "$panns_target"
fi

actual_panns_md5="$(md5sum "$panns_target" | awk '{print $1}')"
echo "MD5 file=$panns_target expected=$panns_md5 actual=$actual_panns_md5"
test "$actual_panns_md5" = "$panns_md5"

echo "=== FINAL MODEL CHECKSUMS ==="
sha256sum \
  "$yamnet_target" \
  "$efficientat_target" \
  "$panns_target" \
  "$yamnet_class_map" \
  "$source_root/EfficientAT/metadata/class_labels_indices.csv" \
  "$source_root/audioset_tagging_cnn/metadata/class_labels_indices.csv"

echo "PASS: reproducible audio benchmark models and sources are ready"
echo "MODEL_ROOT=$model_root"
