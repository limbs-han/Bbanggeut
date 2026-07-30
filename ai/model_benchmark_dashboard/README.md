# WJ Edge Observatory

Jetson Orin Nano에서 실행하는 비전·오디오 모델과 이벤트 파이프라인을
비교하기 위한 LAN 전용 대시보드입니다.

현재 첫 버전은 다음 기능을 제공합니다.

- YOLOv8n, YOLO11n, YOLO26n 비교 표
- FPS, 평균·p95 지연시간, GPU, RAM, 온도 지표
- YAMNet, EfficientAT MN10, PANNs CNN10 비교 계획
- 웃음·연속 박수·사용자 호출명 이벤트의 통합 세션 타임라인
- Jetson 이벤트 파이프라인 단계별 상태
- 로컬 JSONL 파일 가져오기 및 레코드 검증
- 모바일·태블릿·데스크톱 반응형 화면

## 로컬 실행

Node.js 22.13 이상과 pnpm이 필요합니다.

```bash
pnpm install
pnpm dev
```

브라우저에서 `http://localhost:3000`을 엽니다.

```bash
pnpm test
pnpm lint
```

## Jetson 실측 수집기 연결

대시보드는 기본적으로 `http://127.0.0.1:8765/api/snapshot`을 2초마다
조회합니다. Jetson에서 최근 실행 디렉터리와 이벤트 디렉터리를 읽기 전용
수집기에 전달합니다.

```bash
cd ~/william-james

python3 ai/model_benchmark/benchmark_log_collector.py \
  --run-dir ~/ai_events/logs/<RUN_DIRECTORY> \
  --event-dir ~/ai_events \
  --results-dir ~/ai_benchmark_results
```

대시보드를 다른 PC에서 열 때만 명시적으로 LAN 바인딩을 허용합니다.

```bash
python3 ai/model_benchmark/benchmark_log_collector.py \
  --run-dir ~/ai_events/logs/<RUN_DIRECTORY> \
  --event-dir ~/ai_events \
  --results-dir ~/ai_benchmark_results \
  --host 0.0.0.0 \
  --allow-lan \
  --origin http://<DASHBOARD_PC_IP>:3000
```

이 경우 대시보드를 빌드하거나 실행하기 전에 수집기 주소를 지정합니다.

```bash
NEXT_PUBLIC_BENCHMARK_API=http://<JETSON_IP>:8765/api/snapshot pnpm dev
```

수집기는 파일을 수정하지 않으며, 영상·음성 원본을 응답에 포함하지 않습니다.
`--snapshot`을 사용하면 서버를 열지 않고 스냅샷 JSON 한 건만 출력합니다.

## 데이터셋 매니페스트

평가 원본은 Git에 넣지 않고 Jetson 로컬 디렉터리에서 관리합니다.

```bash
python3 ai/model_benchmark/benchmark_dataset.py init \
  --dataset-root ~/ai_datasets/model_benchmark/office-mix-v1 \
  --name office-mix-v1

python3 ai/model_benchmark/benchmark_dataset.py add \
  --dataset-root ~/ai_datasets/model_benchmark/office-mix-v1 \
  --sample-id office-two-people-001 \
  --media ~/ai_datasets/model_benchmark/office-mix-v1/media/scene.mp4 \
  --split test \
  --condition two-people \
  --condition movement \
  --label person:2

python3 ai/model_benchmark/benchmark_dataset.py validate \
  --dataset-root ~/ai_datasets/model_benchmark/office-mix-v1
```

매니페스트는 파일 SHA-256, 크기, 데이터 분할, 촬영 조건, 라벨과 수동 검수
상태를 기록합니다.

## 데모 데이터 상태

화면의 수치는 UI와 수집 스키마를 검증하기 위한 결정적 시뮬레이션
데이터입니다. Jetson 수집기가 응답하면 자동으로 실측 모드로 전환됩니다.

JSONL 가져오기는 한 줄에 JSON 객체 하나인 파일을 읽고 레코드 수를
확인합니다. 이후 Jetson 수집기와 연결할 때 사용할 최소 레코드 예시는
다음과 같습니다.

```json
{
  "schemaVersion": "0.1",
  "observedAt": "2026-07-30T00:00:00.000Z",
  "runId": "WJ-0730-014",
  "component": "vision",
  "model": "yolo11n",
  "runtime": "tensorrt-fp16",
  "metrics": {
    "fps": 31.7,
    "latencyMs": 28.2,
    "gpuPercent": 64,
    "memoryMb": 768,
    "temperatureC": 51
  }
}
```

이벤트 레코드는 원본 영상이나 음성을 포함하지 않고 다음 메타데이터만
사용합니다.

```json
{
  "schemaVersion": "0.1",
  "observedAt": "2026-07-30T00:00:05.000Z",
  "runId": "WJ-0730-014",
  "component": "event",
  "eventType": "LAUGHTER",
  "confidence": 0.84,
  "sessionId": "local-session-id",
  "merged": false
}
```

## 비교 원칙

- 같은 BRIO 100 입력 클립과 같은 객체·오디오 라벨을 사용합니다.
- Jetson 전력 모드, 입력 해상도, 워밍업 프레임을 고정합니다.
- PyTorch와 TensorRT FP16 결과를 섞지 않고 별도 행으로 기록합니다.
- FPS·지연시간뿐 아니라 탐지 정확도, 누락, 오탐, 메모리, 온도와 전력을
  함께 비교합니다.
- 테스트 원본과 식별 가능한 정보는 Jetson 내부에 보관합니다.

## 다음 구현 순서

1. Jetson에서 `tegrastats`, YOLO JSONL, YAMNet JSONL을 모으는 읽기 전용
   수집기 추가
2. 대시보드의 시뮬레이션 데이터 계층을 수집기 API로 교체
3. 동일 데이터셋에서 YOLO 3종 × 런타임 2종 반복 측정
4. YAMNet, EfficientAT MN10, PANNs CNN10 오디오 평가 러너 추가
5. CSV·JSON 결과 내보내기와 실행 간 비교 추가

## 개인정보와 배포

첫 버전은 Jetson 또는 개발 PC의 LAN 안에서만 실행합니다. 외부 호스팅과
자동 배포는 사용하지 않습니다. 원본 영상·음성은 대시보드로 전송하지
않습니다.
