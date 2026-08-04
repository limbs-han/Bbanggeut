# YAMNet–EfficientAT 섀도 검증

## 1. 목적

현재 운영 이벤트 판정기는 YAMNet이다.

EfficientAT MN10은 같은 RTSP 오디오를 읽는 비교 전용 섀도 판정기다.

EfficientAT은 운영 모델 전환 전까지 실제 이벤트를 생성하지 않는다.

EfficientAT은 trigger JSON을 생성하지 않는다.

EfficientAT은 MQTT 메시지를 발행하지 않는다.

EfficientAT은 서버 API를 호출하지 않는다.

EfficientAT은 이벤트 영상을 만들거나 업로드하지 않는다.

## 2. 고정 후보 설정

EfficientAT 모델 입력 문맥은 10초다.

EfficientAT 점수 갱신 간격은 2.5초다.

EfficientAT 웃음 임계값은 `0.01691491`이다.

EfficientAT 웃음 연속 양성 창은 1개다.

EfficientAT 박수 임계값은 `0.08725224`다.

EfficientAT 박수 연속 양성 창은 1개다.

EfficientAT 가상 이벤트 쿨다운은 12초다.

YAMNet 운영 설정은 섀도 비교를 위해 변경하지 않는다.

## 3. 활성화 설정

다음 값은 Jetson의 `/etc/william-james/device-agent.env`에 설정한다.

```dotenv
AUDIO_SHADOW_ENABLED=true
AUDIO_SHADOW_MODEL_PATH=/home/ssafy/ai_models/audio-benchmark/efficientat_mn10_as.pt
AUDIO_SHADOW_MODEL_SHA256=0bd7dc2443af498c289a2e739f02ebb515d6aa3fd3ab9db539c86123ae368a4e
AUDIO_SHADOW_SOURCE_REPO=/home/ssafy/ai_models/audio-benchmark/sources/EfficientAT
AUDIO_SHADOW_SOURCE_COMMIT=a425fdce92572e602a1d5634799bd9f1f2efa806
AUDIO_SHADOW_DEVICE=cuda
AUDIO_SHADOW_PRECISION=fp16
AUDIO_SHADOW_CONTEXT_SECONDS=10
AUDIO_SHADOW_HOP_SECONDS=2.5
AUDIO_SHADOW_LAUGHTER_THRESHOLD=0.01691491
AUDIO_SHADOW_LAUGHTER_CONSECUTIVE=1
AUDIO_SHADOW_CLAP_THRESHOLD=0.08725224
AUDIO_SHADOW_CLAP_CONSECUTIVE=1
AUDIO_SHADOW_COOLDOWN_SECONDS=12
```

기본값 `AUDIO_SHADOW_ENABLED=false`에서는 추가 모델을 로드하지 않는다.

섀도 활성화는 장치에 자동 배포하지 않는다.

기능 MR의 CI가 성공한 뒤 사용자가 Jetson 적용을 명시적으로 승인해야 한다.

## 4. 실행 구조

`run_edge_ai_recording.sh`가 YAMNet을 먼저 시작한다.

YAMNet은 첫 추론 준비 여부와 무관하게 운영 이벤트 권한을 유지한다.

YOLO와 업로더가 시작된 뒤 EfficientAT 섀도 실행기가 시작된다.

EfficientAT 섀도 실행기는 최근 10초 PCM을 유지한다.

EfficientAT 섀도 실행기는 새로운 PCM 2.5초가 들어올 때마다 추론한다.

섀도 활성화 시 동일 RTSP를 읽는 FFmpeg 프로세스가 일반적으로 1개 증가한다.

RTSP 연결이 끊기면 기존 오디오 문맥을 버린다.

RTSP 재연결 후에는 새로운 10초 문맥이 모인 뒤 추론을 재개한다.

EfficientAT 섀도 실행기가 종료되면 운영 서비스는 중단하지 않는다.

EfficientAT 섀도 실행기만 기본 10초 후 다시 시작한다.

## 5. 기록 파일

실행 디렉터리는 `~/ai_events/logs/YYYYMMDD_HHMMSS`다.

YAMNet 운영 진단은 `yamnet_diagnostics.jsonl`에 기록한다.

EfficientAT 섀도 점수는 `efficientat_shadow.jsonl`에 기록한다.

EfficientAT 프로세스 표준 로그는 `efficientat_shadow.log`에 기록한다.

EfficientAT의 `virtual-event` 레코드는 가상 이벤트다.

가상 이벤트 ID에는 `shadow-` 접두사를 붙인다.

가상 이벤트에는 `operationalAuthority=false`를 기록한다.

각 EfficientAT 예측에는 웃음 점수와 박수 점수를 함께 기록한다.

각 EfficientAT 예측에는 입력 창의 시작·종료 시각을 기록한다.

각 EfficientAT 예측에는 추론 지연과 상위 클래스를 기록한다.

## 6. 실시간 확인

벤치마크 수집기 스냅샷은 `audio`에 YAMNet 상태를 제공한다.

벤치마크 수집기 스냅샷은 `audioShadow`에 EfficientAT 상태를 제공한다.

`audioShadow.operationalAuthority`는 항상 `false`다.

```bash
curl -fsS http://127.0.0.1:18765/api/snapshot | python3 -m json.tool
```

대시보드 오디오 탭은 YAMNet 운영 점수와 EfficientAT 섀도 점수를 분리해 표시한다.

대시보드는 EfficientAT의 운영 이벤트 권한을 `DISABLED`로 표시한다.

## 7. 비교 보고서 생성

비교 보고서는 동일 실행 디렉터리의 두 JSONL을 입력으로 사용한다.

```bash
run_dir="$HOME/ai_events/logs/<실행 디렉터리>"
result_dir="$HOME/ai_benchmark_results/audio-shadow-$(date -u +%Y%m%dT%H%M%SZ)"

"$HOME/venvs/yolo/bin/python" \
  "$HOME/ai/model_benchmark/audio_shadow_report.py" \
  --yamnet-diagnostics "$run_dir/yamnet_diagnostics.jsonl" \
  --shadow-diagnostics "$run_dir/efficientat_shadow.jsonl" \
  --output-dir "$result_dir" \
  --match-tolerance-seconds 12
```

`summary.json`은 기계 판독용 집계를 저장한다.

`summary.md`는 발표와 검토에 사용할 표를 저장한다.

`manual-review.jsonl`은 사람이 확인해야 하는 불일치 항목을 저장한다.

YAMNet 단독 이벤트는 정답 확인 전까지 EfficientAT 미탐으로 단정하지 않는다.

EfficientAT 단독 이벤트는 정답 확인 전까지 EfficientAT 오탐으로 단정하지 않는다.

사람이 원음을 확인한 뒤에만 FP와 FN을 확정한다.

## 8. 1차 판정 기준 초안

웃음 Recall 목표는 `0.90` 이상이다.

박수 Recall 목표는 `0.90` 이상이다.

웃음+박수 동시 감지 목표는 `0.80` 이상이다.

검수 완료 음성의 거짓 이벤트 목표는 이벤트별 시간당 1건 이하다.

EfficientAT 감지 지연 P95 목표는 음향 발생 후 3초 이하다.

YOLO 처리량 목표는 동시 실행 중 20 FPS 이상이다.

섀도 실행 중 Edge AI 서비스 비정상 재시작 허용 횟수는 0회다.

동시 실행 중 CUDA 비정상 종료 허용 횟수는 0회다.

이 값은 운영 전환 승인 기준의 초안이다.

실제 섀도 실행 전에 사용자와 최종 검증 시간 및 목표 이벤트 수를 확정한다.

## 9. 전환 금지 조건

사람이 검수하지 않은 모델 불일치를 FP나 FN으로 계산하면 안 된다.

계획된 아기·어린이 웃음 표본이 없으면 해당 조건이 검증됐다고 말하면 안 된다.

계획된 다인 웃음 표본이 없으면 해당 조건이 검증됐다고 말하면 안 된다.

계획된 10m 표본이 없으면 10m 성능이 검증됐다고 말하면 안 된다.

섀도 기준을 통과하지 못하면 YAMNet 운영 권한을 유지한다.

섀도 기준을 통과해도 별도의 이벤트 업로드 종단 검증 전에는 모델을 교체하지 않는다.

## 10. 자동 회귀 검증

CI는 `audio_accuracy_runner.py`와 `audio_prediction_runner.py`를 `py_compile`로 검사한다.

CI는 두 추론 실행기의 `--help` 진입점을 실행해 파일 본문과 import 경로를 확인한다.

서비스 격리 테스트는 운영 서비스 네 개가 모두 중지되는지 확인한다.

서비스 기본 복원 테스트는 서보가 정지 상태로 유지되는지 확인한다.

서비스 명시 복원 테스트는 `--restore-servo`가 있을 때만 서보가 복원되는지 확인한다.

데이터셋 테스트는 동일한 `sessionId`가 validation과 test에 있으면 검증 오류가 발생하는지 확인한다.

데이터셋 동시 쓰기 테스트는 여러 프로세스의 샘플 추가가 유실되지 않는지 확인한다.

섀도 종단 테스트는 가짜 RTSP 입력과 EfficientAT 점수로 실제 JSONL 기록 경로를 실행한다.

섀도 종단 테스트는 시작 기록의 모든 부작용 권한이 `false`인지 확인한다.

섀도 종단 테스트는 가상 이벤트의 `operationalAuthority`가 `false`인지 확인한다.

Jetson 실제 RTSP와 모델을 사용하는 현장 종단 검증은 자동 회귀 검증과 별도로 수행한다.

## 11. 비활성화

`AUDIO_SHADOW_ENABLED=false`로 변경하면 다음 서비스 시작부터 EfficientAT을 로드하지 않는다.

비활성화해도 기존 YAMNet 운영 설정은 바뀌지 않는다.

```bash
sudo systemctl restart wj-edge-ai-recording
```
