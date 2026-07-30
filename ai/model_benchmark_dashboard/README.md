# WJ Edge Observatory

Jetson Orin Nano의 운영 로그와 모델 비교 결과를 읽는 LAN 전용
대시보드입니다. 영상·음성 원본은 전송하지 않고 성능 수치와 이벤트
메타데이터만 표시합니다.

## 표시 원칙

- 수집되지 않은 수치는 추정하거나 샘플값으로 채우지 않고 `N/A`로 표시합니다.
- 수집기 상태는 `LIVE`, `PARTIAL`, `OFFLINE`으로 구분합니다.
- `tegrastats`, YOLO 로그, YAMNet 진단 JSONL의 갱신 시각을 각각 확인합니다.
- `summary.json`이 있는 완료 벤치마크만 모델 비교 표에 표시합니다.
- `progress.json`이 있으면 실행 중 모델·표본·프레임 진행률을 표시합니다.
- 정확도 라벨이 없으면 precision, recall, mAP를 계산했다고 표시하지 않습니다.

## 대시보드 실행

Node.js 22.13 이상과 pnpm이 필요합니다.

```bash
cd ai/model_benchmark_dashboard
pnpm install
pnpm dev
```

브라우저에서 `http://127.0.0.1:3000`을 엽니다.

```bash
pnpm test
pnpm lint
```

## Jetson 수집기 실행

기본 포트는 `18765`입니다. `8765`는 서보 대시보드가 사용할 수 있으므로
벤치마크 수집기에서 사용하지 않습니다.

Jetson에서 가장 최근 운영 실행 디렉터리를 자동 추적합니다.

```bash
cd ~/william-james

python3 ai/model_benchmark/benchmark_log_collector.py \
  --logs-root ~/ai_events/logs \
  --event-dir ~/ai_events \
  --results-dir ~/ai_benchmark_results \
  --host 127.0.0.1 \
  --port 18765
```

특정 실행을 고정해서 확인할 때만 `--logs-root` 대신 아래 옵션을 사용합니다.

```bash
--run-dir ~/ai_events/logs/<RUN_DIRECTORY>
```

단일 JSON 확인:

```bash
python3 ai/model_benchmark/benchmark_log_collector.py \
  --logs-root ~/ai_events/logs \
  --event-dir ~/ai_events \
  --results-dir ~/ai_benchmark_results \
  --snapshot
```

## Windows에서 SSH 터널 연결

Jetson의 수집기를 loopback에 유지한 채 Windows에서 접근합니다.

```powershell
ssh -N `
  -L 8765:127.0.0.1:18765 `
  ssafy@<JETSON_IP>
```

대시보드는 기본적으로 Windows의
`http://127.0.0.1:8765/api/snapshot`을 조회합니다. 즉, 위 SSH 터널 명령과
추가 설정 없이 연결됩니다. 다른 로컬 포트를 쓸 때만 다음 환경 변수를
지정합니다.

```powershell
$env:NEXT_PUBLIC_BENCHMARK_API = "http://127.0.0.1:<LOCAL_PORT>/api/snapshot"
pnpm dev
```

연결 확인:

```powershell
Invoke-RestMethod "http://127.0.0.1:8765/api/health"
Invoke-RestMethod "http://127.0.0.1:8765/api/snapshot"
```

## 평가 데이터셋

원본은 Jetson의 `~/ai_datasets/model_benchmark/` 아래에 두고 Git에
커밋하지 않습니다.

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

공정한 비교를 위해 같은 BRIO 100 입력, 데이터셋, 해상도, 전력 모드,
warm-up 프레임, 측정 프레임, 반복 횟수를 사용합니다. PyTorch와 TensorRT
FP16 결과는 같은 값으로 섞지 않고 런타임별로 구분합니다.
