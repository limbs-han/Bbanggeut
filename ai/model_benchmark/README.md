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
  --warmup-frames 30 \
  --max-frames 300 \
  --repeats 3
```

각 프레임 결과는 `frames.jsonl`, 실행 요약은 `summary.json`, 실행 상태는
`progress.json`에 저장됩니다.
프레임 단위 바운딩박스 정답이 없는 데이터셋에서는 정확도나 mAP를 계산했다고
표시하지 않고 `not-computed`로 남깁니다.

## 데이터셋 조건

첫 비교 세트에는 다음 조건을 균형 있게 포함합니다.

- 비전: `empty`, `single-person`, `two-people`, `movement`, `occlusion`,
  `low-light`
- 오디오: `laughter`, `speech`, `consecutive-clap`, `tv-playback`

원본은 `~/ai_datasets/model_benchmark/`에 두고 Git에는 올리지 않습니다.

## 검증

```bash
python3 -m unittest discover \
  -s ai/model_benchmark \
  -p 'test_benchmark_*.py'
```

## 다음 러너

동일 데이터 매니페스트를 소비하는 다음 러너를 순차적으로 추가합니다.

1. YOLOv8n·YOLO11n·YOLO26n × PyTorch·TensorRT FP16
2. YAMNet·EfficientAT MN10·PANNs CNN10
3. 반복 실행 결과의 CSV·JSON 요약과 대시보드 자동 반영
