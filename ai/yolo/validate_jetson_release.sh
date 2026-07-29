#!/usr/bin/env bash

# Validate a staged AI release on Jetson without changing any service state.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
YAMNET_DIR="${AI_DIR}/yamnet"
DEVICE_AGENT_DIR="${AI_DIR}/device_agent"

YOLO_PYTHON="${YOLO_PYTHON:-${HOME}/venvs/yolo/bin/python}"
YAMNET_PYTHON="${YAMNET_PYTHON:-${HOME}/venvs/yamnet/bin/python}"

required_files=(
    "$YOLO_PYTHON"
    "$YAMNET_PYTHON"
    "${SCRIPT_DIR}/yolov8n.pt"
    "${SCRIPT_DIR}/yolov8_autoframe_jetson.py"
    "${SCRIPT_DIR}/servo_controller.py"
    "${SCRIPT_DIR}/servo_dashboard.py"
    "${SCRIPT_DIR}/servo_dashboard_web/index.html"
    "${SCRIPT_DIR}/servo_dashboard_web/styles.css"
    "${SCRIPT_DIR}/servo_dashboard_web/app.js"
    "${SCRIPT_DIR}/requirements-servo-controller.txt"
    "${SCRIPT_DIR}/test_servo_controller.py"
    "${SCRIPT_DIR}/test_servo_dashboard.py"
    "${SCRIPT_DIR}/wj-servo-controller.service"
    "${SCRIPT_DIR}/stream_capture.py"
    "${SCRIPT_DIR}/run_ai_stack.sh"
    "${SCRIPT_DIR}/run_edge_ai_mvp.sh"
    "${SCRIPT_DIR}/run_edge_ai_recording.sh"
    "${SCRIPT_DIR}/run_yolo_rtsp_validation.sh"
    "${YAMNET_DIR}/yamnet_laughter_detect_jetson.py"
    "${YAMNET_DIR}/ffmpeg_audio_stream.py"
    "${YAMNET_DIR}/laughter_eval_dataset.py"
    "${YAMNET_DIR}/laughter_scoring.py"
    "${YAMNET_DIR}/mqtt_event_publisher.py"
)

for required_file in "${required_files[@]}"; do
    if [[ ! -e "$required_file" ]]; then
        echo "Required release file not found: $required_file" >&2
        exit 1
    fi
done

echo "[1/4] Bash syntax"
bash -n \
    "${SCRIPT_DIR}/run_ai_stack.sh" \
    "${SCRIPT_DIR}/run_edge_ai_mvp.sh" \
    "${SCRIPT_DIR}/run_edge_ai_recording.sh" \
    "${SCRIPT_DIR}/run_yolo_rtsp_validation.sh"
if [[ -f "${DEVICE_AGENT_DIR}/integration-soak-test.sh" ]]; then
    bash -n "${DEVICE_AGENT_DIR}/integration-soak-test.sh"
fi
grep -Fq ': "${YAMNET_SCORE_AGGREGATION:=mean}"' \
    "${SCRIPT_DIR}/run_edge_ai_recording.sh"
grep -Fq ': "${YAMNET_THRESHOLD:=0.125}"' \
    "${SCRIPT_DIR}/run_edge_ai_recording.sh"
grep -Fq ': "${YAMNET_CONSECUTIVE:=3}"' \
    "${SCRIPT_DIR}/run_edge_ai_recording.sh"
grep -Fq ': "${SERVO_DASHBOARD_HOST:=127.0.0.1}"' \
    "${SCRIPT_DIR}/run_edge_ai_recording.sh"
grep -Fq -- '--score-aggregation "$YAMNET_SCORE_AGGREGATION"' \
    "${SCRIPT_DIR}/run_edge_ai_recording.sh"

echo "[2/4] Python syntax"
PYTHONDONTWRITEBYTECODE=1 "$YOLO_PYTHON" -m py_compile \
    "${SCRIPT_DIR}/yolov8_autoframe_jetson.py" \
    "${SCRIPT_DIR}/servo_controller.py" \
    "${SCRIPT_DIR}/servo_dashboard.py" \
    "${SCRIPT_DIR}/stream_capture.py" \
    "${SCRIPT_DIR}/event_fusion_service.py" \
    "${SCRIPT_DIR}/laughter_clip_uploader.py" \
    "${SCRIPT_DIR}/segment_clip_uploader.py" \
    "${SCRIPT_DIR}/summarize_yolo_validation.py" \
    "${SCRIPT_DIR}/vision_mqtt_publisher.py"
PYTHONDONTWRITEBYTECODE=1 "$YAMNET_PYTHON" -m py_compile \
    "${YAMNET_DIR}/yamnet_laughter_detect_jetson.py" \
    "${YAMNET_DIR}/ffmpeg_audio_stream.py" \
    "${YAMNET_DIR}/laughter_eval_dataset.py" \
    "${YAMNET_DIR}/laughter_scoring.py" \
    "${YAMNET_DIR}/mqtt_event_publisher.py"

echo "[3/4] YOLO-side tests"
(
    cd -- "$SCRIPT_DIR"
    PYTHONDONTWRITEBYTECODE=1 "$YOLO_PYTHON" \
        -m unittest \
        test_autoframe_logic \
        test_servo_controller \
        test_servo_dashboard \
        test_event_fusion \
        test_laughter_clip_uploader \
        test_stream_capture \
        test_segment_clip_uploader \
        test_summarize_yolo_validation
)

echo "[4/4] YAMNet stream tests"
(
    cd -- "$YAMNET_DIR"
    PYTHONDONTWRITEBYTECODE=1 "$YAMNET_PYTHON" \
        -m unittest \
        test_ffmpeg_audio_stream \
        test_laughter_eval_dataset \
        test_laughter_scoring
)

echo "PASS: staged Jetson AI release validation completed."
