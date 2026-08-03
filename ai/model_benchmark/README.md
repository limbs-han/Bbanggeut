# AI model benchmark tools

Jetson에서 모델을 공정하게 비교하기 위한 로컬 전용 도구 모음입니다.

## 포함된 도구

- `benchmark_log_collector.py`
  - `tegrastats`, YOLO 상태 로그, YAMNet 진단 JSONL을 읽습니다.
  - 영상·음성 원본을 노출하지 않는 스냅샷 API를 제공합니다.
  - 기본값은 `127.0.0.1:18765`이며 서보 대시보드의 `8765`와 충돌하지
    않습니다. 외부 인터페이스는 명시적인
    `--allow-lan` 없이는 열리지 않습니다.
- `benchmark_dataset.py`
  - 평가 데이터셋의 로컬 JSON 매니페스트를 생성합니다.
  - 파일 SHA-256, 크기, 분할, 촬영 조건과 라벨을 검증합니다.
- `vision_accuracy_runner.py`
  - YOLO 형식의 프레임별 정답 박스로 표준 mAP와 운영 임계값 정확도를
    분리해 계산합니다.
  - 모델·데이터셋 SHA-256, 조건별 FP/FN, 실패 프레임, Jetson 자원 사용량을
    함께 기록합니다.
- `models/`
  - 기존 PC 재현용 소형 모델 파일입니다.
  - TensorRT 엔진은 Jetson 환경 의존적이므로 저장소에 커밋하지 않습니다.

## 수집기 빠른 확인

```bash
python3 benchmark_log_collector.py \
  --logs-root ~/ai_events/logs \
  --event-dir ~/ai_events \
  --results-dir ~/ai_benchmark_results \
  --snapshot
```

HTTP API를 실행합니다.

```bash
python3 benchmark_log_collector.py \
  --logs-root ~/ai_events/logs \
  --event-dir ~/ai_events \
  --results-dir ~/ai_benchmark_results
```

- 상태: `GET /api/health`
- 스냅샷: `GET /api/snapshot`

`--logs-root`는 요청마다 가장 최근에 활동한 실행 디렉터리를 다시 찾습니다.
특정 실행을 고정하려면 대신 `--run-dir`을 사용합니다. API는 소스 파일의
갱신 시각과 stale 여부도 함께 반환합니다.

`--results-dir` 아래의 `*/summary.json`은 원본 경로를 제거한 뒤 대시보드의
모델 비교 표에 반영됩니다. 실행 중에는 `progress.json`이 원자적으로
갱신되므로 현재 모델·표본·프레임 진행률을 확인할 수 있습니다.

## YOLO 비교 러너

러너는 모델을 자동으로 다운로드하지 않습니다. Jetson에 명시적으로 준비한
`.pt`, `.onnx`, `.engine` 파일만 사용합니다.

```bash
python3 vision_benchmark_runner.py \
  --dataset-root ~/ai_datasets/model_benchmark/office-mix-v1 \
  --model ~/ai_models/yolo11n.engine \
  --model-name YOLO11n \
  --output-dir ~/ai_benchmark_results/yolo11n-trt-fp16 \
  --device 0 \
  --confidence 0.25 \
  --iou 0.7 \
  --class-id 0 \
  --warmup-frames 30 \
  --max-frames 300 \
  --repeats 3
```

각 프레임 결과는 `frames.jsonl`, 실행 요약은 `summary.json`, 실행 상태는
`progress.json`에 저장됩니다.
프레임 단위 바운딩박스 정답이 없는 데이터셋에서는 정확도나 mAP를 계산했다고
표시하지 않고 `not-computed`로 남깁니다.

`--class-id 0`은 COCO의 `person` 클래스만 비교한다는 뜻입니다. 공정한 모델
비교를 위해 confidence, IoU, 클래스 필터를 모든 실행에서 같은 값으로
명시하고, 해당 값은 `summary.json`의 `configuration`에 기록합니다.

## YOLO 정확도 러너

라벨링된 정적 프레임은 영상 처리량 러너와 분리해 평가합니다. 표준 mAP는
전체 PR 곡선을 만들 수 있도록 낮은 confidence floor를 사용하고, 실제 서비스
판정은 운영 confidence `0.25`에서 Precision·Recall·F1을 다시 계산합니다.

```bash
python3 vision_accuracy_runner.py \
  --dataset-root \
    ~/ai_datasets/model_benchmark/office-vision-gt-v1/exports/yolo-person-test-406 \
  --model ~/ai_models/yolo-detect-pt/yolo11n.pt \
  --model-name YOLO11n \
  --output-dir ~/ai_benchmark_results/yolo-accuracy/yolo11n \
  --device 0 \
  --imgsz 640 \
  --batch 1 \
  --map-confidence 0.001 \
  --operating-confidence 0.25 \
  --nms-iou 0.7 \
  --match-iou 0.5 \
  --class-id 0
```

결과물은 다음 질문에 재현 가능한 수치로 답하도록 구성합니다.

1. 최신 모델이나 공개 COCO 수치가 아니라 왜 해당 모델을 선택했는가?
2. 실제 Jetson·홈캠 환경에서도 정확도와 실시간성을 모두 만족하는가?

기본 선정 가이드는 `FPS ≥ 20`, `Wall P95 ≤ 50ms`, 운영 Recall `≥ 0.90`,
최고 mAP50-95 대비 차이 `≤ 0.02`입니다. 모든 기준을 통과한 후보 중 FPS가
높은 모델을 우선합니다. 첫 실측 후 서비스 요구에 따라 기준값을 확정합니다.

세 모델을 같은 설정으로 반복 실행할 때는 운영 Edge AI를 먼저 중지하고 다음
스크립트를 사용합니다. 스크립트는 검증된 406장·597박스 데이터셋과 세 개의
로컬 모델 파일을 확인하며 모델을 자동 다운로드하지 않습니다. 기본값은 모델별
3회입니다. 회차마다 시작 모델을 바꿔 열·캐시·실행 순서 편향을 줄입니다.

```bash
sudo systemctl stop wj-edge-ai-recording

cd ~/william-james
bash ai/model_benchmark/run_yolo_accuracy_comparison.sh
```

반복 횟수와 실행 사이 냉각 시간은 `YOLO_REPEAT_COUNT`와
`YOLO_COOLDOWN_SECONDS`로 바꿀 수 있습니다. 각 `summary.json`에는 비교 ID,
회차, 전체 회차 수와 실제 실행 순서가 함께 기록됩니다.

각 모델 사이에는 기본 30초 냉각 시간을 두며 `YOLO_COOLDOWN_SECONDS`로
조정할 수 있습니다. 시험 후에는 사용자가 명시적으로 운영 서비스를 다시
시작해야 합니다.

## 웃음·연속 박수 모델 비교

세 후보(YAMNet TFLite, EfficientAT MN10, PANNs CNN10)는 동일한 WAV와
0.975초 창을 사용해 웃음과 박수 점수를 한 번에 생성합니다. 임계값은
validation에서만 선택하며 test에는 고정합니다. 선택 우선순위는 시간당
오탐 이벤트, Recall 0.85 충족 여부, Macro F1, P95 지연시간 순입니다.

원본 음성은 Jetson 로컬에만 두고 Git에는 매니페스트 구조와 실행 코드만
저장합니다.

```bash
# 앱 연결·상시 녹화·이벤트 업로드·서보를 중단하고 로컬 RTSP만 유지
bash ai/model_benchmark/audio_benchmark_services.sh isolate

# validation 60개 + test 60개 수집 계획 생성
python3 ai/model_benchmark/audio_dataset_capture.py init \
  --dataset-root ~/ai_datasets/model_benchmark/office-audio-events-v1

python3 ai/model_benchmark/audio_dataset_capture.py capture \
  --dataset-root ~/ai_datasets/model_benchmark/office-audio-events-v1 \
  --split validation

python3 ai/model_benchmark/audio_dataset_capture.py capture \
  --dataset-root ~/ai_datasets/model_benchmark/office-audio-events-v1 \
  --split test

# 오탐/시간 검증용 4개 × 15분 연속 음성
python3 ai/model_benchmark/audio_negative_capture.py \
  --dataset-root ~/ai_datasets/model_benchmark/office-audio-events-v1

# ESC-50 v2.0.0을 고정 커밋·체크섬으로 내려받아 test에 추가
python3 ai/model_benchmark/prepare_esc50_audio_benchmark.py \
  --dataset-root ~/ai_datasets/model_benchmark/office-audio-events-v1 \
  --download \
  --append

# 세 모델과 공식 소스를 고정 버전으로 준비한 뒤 3회 순환 평가
bash ai/model_benchmark/prepare_audio_benchmark_models.sh
bash ai/model_benchmark/run_audio_accuracy_comparison.sh

# 시험 전에 active였던 서비스 복원(서보는 안전상 자동 복원하지 않음)
bash ai/model_benchmark/audio_benchmark_services.sh restore
```

ESC-50는 CC BY-NC 3.0이므로 비상업적 평가에만 사용합니다. 공개 모델 세 개가
모두 AudioSet 계열 사전학습 모델인 점을 고려해 AudioSet 자체는 최종 일반화
평가 데이터로 사용하지 않습니다.

## 데이터셋 조건

첫 비교 세트에는 다음 조건을 균형 있게 포함합니다.

- 비전: `empty`, `single-person`, `two-people`, `movement`, `occlusion`,
  `low-light`
- 오디오: `laughter`, `laughter-with-clap`, `consecutive-clap`,
  `conversation`, `single-impact`, `music`, `tv-playback`, `daily-noise`

원본은 `~/ai_datasets/model_benchmark/`에 두고 Git에는 올리지 않습니다.

## 검증

```bash
python3 -m unittest discover \
  -s ai/model_benchmark \
  -p 'test_*.py'
```

## 확장 예정

현재 YOLO와 오디오 모델의 단독 반복 평가, CSV·JSON·Markdown 요약 및
대시보드 반영까지 지원합니다. 다음 단계에서는 1차 기준을 통과한 오디오
모델을 YOLOv8n TensorRT FP16과 동시에 실행해 자원 경합과 이벤트 종단 동작을
검증합니다.

## 실측 보고서

- [2026-08-02 YOLO TensorRT FP16 정확도·실시간성 비교](./reports/20260802_yolo_tensorrt_fp16_accuracy/README.md)
