# YOLOv8n TensorRT FP16 운영 전환 보고서

## 1. 결론

William James 홈캠의 운영 객체 탐지 모델은 **YOLOv8n을 유지하고, 실행 런타임은 PyTorch에서 TensorRT FP16으로 전환**했다.

이 결정은 최신 모델이라는 이유나 단일 속도 수치만으로 내리지 않았다. 같은 Jetson과 같은 라벨 데이터에서 YOLOv8n·YOLO11n·YOLO26n을 TensorRT FP16으로 비교한 결과, YOLOv8n이 서비스 기준을 모두 통과하면서 운영 임계값의 F1이 가장 높고 오탐과 미탐의 합이 가장 적었다. 이후 실제 운영 스택에서 Live View, 3명 추적, 로컬 녹화, 음성 연결까지 종단 검증해 배포 가능성을 확인했다.

핵심은 다음 두 판단을 분리한 것이다.

- **모델 선택:** 세 후보 중 정확도와 실시간성의 균형이 가장 좋은 YOLOv8n을 선택했다.
- **런타임 선택:** 선택한 YOLOv8n을 Jetson에서 효율적으로 실행하기 위해 TensorRT FP16 엔진으로 배포했다.

## 2. 같은 YOLOv8n인데 TensorRT FP16으로 바꾼 이유

YOLOv8n은 객체 탐지 구조와 학습된 가중치를 뜻하고, PyTorch와 TensorRT는 그 모델을 실행하는 방식이다. 따라서 이번 전환은 다른 모델로 재학습한 것이 아니라, **같은 YOLOv8n을 Jetson 배포 환경에 맞는 엔진으로 변환한 것**이다.

NVIDIA는 TensorRT를 NVIDIA GPU에서 딥러닝 추론을 최적화하고 가속하는 SDK로 설명한다. TensorRT는 PyTorch나 ONNX 모델을 배포용 엔진으로 만들고 FP16을 포함한 혼합 정밀도 실행을 지원한다. 이번 프로젝트에서는 Jetson Orin Nano에서 고정 입력 `640×640`, batch 1 조건으로 FP16 엔진을 생성했다.

FP16을 선택한 이유는 다음과 같다.

- 홈캠은 단발성 분석보다 영상 프레임을 지속해서 처리하므로 추론 지연과 처리량이 중요하다.
- Jetson의 NVIDIA GPU에 맞춰 생성된 TensorRT 엔진을 사용하면 범용 PyTorch 실행 경로보다 배포 환경에 특화된 실행 계획을 사용할 수 있다.
- FP16은 FP32보다 낮은 정밀도를 사용하므로 성능 최적화 여지가 있지만, INT8처럼 별도의 보정 데이터 절차를 추가하지 않고 적용할 수 있다.
- 정밀도 감소가 탐지 결과에 영향을 줄 가능성은 있으므로, 변환 성공만 확인하지 않고 수동 라벨 데이터셋으로 정확도를 다시 측정했다.

TensorRT 엔진은 기본적으로 빌드한 TensorRT 버전과 GPU 환경의 영향을 받는다. 따라서 엔진 파일을 일반 모델 파일처럼 모든 장치에 그대로 배포하지 않고, 대상 Jetson에서 역직렬화와 실제 추론을 검증한 뒤 운영에 반영했다.

## 3. 평가 환경

| 항목 | 조건 |
|---|---|
| 장치 | NVIDIA Jetson Orin Nano |
| 전력 모드 | 25W |
| 후보 모델 | YOLOv8n, YOLO11n, YOLO26n |
| 런타임 | TensorRT FP16 |
| 입력 | 640×640, batch 1 |
| 탐지 클래스 | COCO `person` |
| 데이터셋 | `yolo-person-test-395-dedup` |
| 평가 이미지 | 395장 |
| 빈 장면 | 52장 |
| 사람 정답 박스 | 581개 |
| 중복 이미지 | 0장 |
| 반복 횟수 | 모델별 3회, 총 9회 |
| 운영 confidence | 0.25 |
| 정답 매칭 IoU | 0.5 |

실행 순서에 따른 발열이나 직전 실행 상태의 영향을 줄이기 위해 각 모델이 첫 번째·두 번째·세 번째 실행 위치를 한 번씩 맡도록 순서를 회전했다.

모델 선택 기준은 다음과 같이 사전에 정했다.

- 평균 FPS 20 이상
- Wall P95 50ms 이하
- 운영 Recall 90% 이상
- 최고 mAP50-95와의 격차 2.0%p 이내
- 위 기준을 통과한 후보 중 운영 오류와 실시간성을 함께 비교

## 4. TensorRT FP16 비교 결과

| 모델 | 평균 FPS | 추론 평균 | Wall P95 | mAP50-95 | 운영 Precision / Recall / F1 | FP / FN |
|---|---:|---:|---:|---:|---:|---:|
| **YOLOv8n** | 27.095 | **14.530ms** | 39.303ms | 81.3% | 96.89% / 96.56% / **96.72%** | **18 / 20** |
| YOLO11n | 26.563 | 15.155ms | 40.008ms | **81.9%** | 94.90% / 96.04% / 95.47% | 30 / 23 |
| YOLO26n | **29.203** | 15.012ms | **36.555ms** | 79.7% | 95.04% / 92.25% / 93.62% | 28 / 45 |

YOLO11n은 mAP50-95가 YOLOv8n보다 0.6%p 높았다. 그러나 실제 서비스 confidence 0.25에서는 YOLOv8n의 F1이 더 높았고, YOLO11n보다 오탐이 12건, 미탐이 3건 적었다.

YOLO26n은 평균 FPS가 가장 높았지만 최고 mAP50-95와의 차이가 2.2%p로 허용 기준을 넘었다. 특히 두 사람이 교차하는 조건에서 F1이 69.23%였고 전체 미탐도 45건으로 가장 많았다. 홈캠은 탐지된 사람 수와 그룹 중심을 이용해 카메라 방향을 결정하므로, 교차·가림 상황의 미탐은 단순 정지 이미지 수치보다 서비스 동작에 더 직접적인 영향을 준다.

YOLOv8n은 최고 mAP 모델과 0.6%p 차이 안에 머물면서 운영 F1 96.72%, Recall 96.56%, 평균 27.095 FPS를 기록했다. 따라서 속도 하나만 가장 높은 후보 대신, **정확도와 실시간성 기준을 모두 만족하고 실제 운영점 오류가 가장 적은 후보**로 선택했다.

## 5. PyTorch 측정과의 관계

초기 PyTorch CUDA 비교에서는 YOLOv8n이 평균 28.216 FPS, 평균 추론 23.172ms, Wall P95 37.917ms로 세 후보 중 가장 좋은 실시간성을 기록했다. 이 결과는 YOLOv8n을 우선 후보로 삼는 근거가 됐다.

다만 초기 PyTorch 시험은 9개 영상 장면에서 모델별 8,100프레임을 처리했고, TensorRT 정확도 시험은 라벨링된 395장으로 진행했다. 데이터셋과 실행 도구가 다르기 때문에 두 결과만으로 “TensorRT 전환 후 FPS가 몇 퍼센트 증가했다”고 직접 계산하지 않는다.

TensorRT 전환에 대해 이번에 확실히 검증한 범위는 다음과 같다.

- YOLOv8n FP16 엔진이 대상 Jetson에서 정상적으로 로드되고 추론된다.
- 라벨 데이터에서 서비스 정확도 기준을 통과한다.
- 동일 TensorRT 조건의 다른 후보보다 운영 F1과 FP·FN 결과가 유리하다.
- 실제 운영 스택에서 요구되는 처리 속도와 안정성을 만족한다.

PyTorch 대비 순수 런타임 향상률이 필요하다면 같은 395장, 같은 runner, 같은 전처리·후처리 조건에서 `YOLOv8n.pt`와 `YOLOv8n.engine`만 바꿔 추가 측정해야 한다.

## 6. 운영 종단 검증

2026년 8월 3일 실제 운영 환경에서 immutable release로 전환한 뒤 다음 항목을 확인했다.

| 검증 항목 | 결과 |
|---|---|
| 활성 릴리스 | `20260803T020759Z_yolov8n_tensorrt_runtime` |
| 런타임 선택 | `tensorrt` |
| 엔진 SHA-256 | `cea7f5dd8393ccd8b1e67489f4e58085f4ad3547883076dd2fc41833a652a1f1` |
| Live View 연결 | 12초 후 relay 확인 |
| 앱 영상·음성 | 모두 정상 |
| 실제 사람 수 | 3명 |
| 사람 추적 상태 | 1초 후 `TRACKING` 확인 |
| 운영 로그 FPS | 20.6 FPS |
| 처리 프레임 | 5,495 → 6,501 증가 확인 |
| Live View 종료 | 44초 후 relay 정리 |
| 서비스 재시작 | 0회 |
| 최종 FFmpeg | 기준값 3개로 복귀 |
| AI 작업 프로세스 | YOLO·YAMNet·Uploader 각각 1개 |
| 로컬 RTSP·녹화 | 모두 정상 |

운영 로그의 20.6 FPS는 Live View를 함께 실행하고 실제 3명을 추적하던 한 시점의 값이다. 모델 비교의 3회 평균 27.095 FPS와 측정 조건이 다르므로 같은 성능 지표로 합치지 않고, **서비스 부하가 있는 상태에서도 최소 20 FPS 기준을 지켰다는 종단 검증값**으로만 사용한다.

## 7. 안전한 전환 방식

TensorRT 엔진이 없거나 손상됐을 때 PyTorch로 조용히 되돌아가면 운영자는 전환 실패를 알아채기 어렵다. 운영 설정에서는 이를 방지하기 위해 다음 값을 사용한다.

```ini
YOLO_RUNTIME=tensorrt
YOLO_TENSORRT_ENGINE_PATH=/home/ssafy/ai_models/yolo-detect-engine/yolov8n-fp16-b1-640.engine
YOLO_TENSORRT_ENGINE_SHA256=cea7f5dd8393ccd8b1e67489f4e58085f4ad3547883076dd2fc41833a652a1f1
YOLO_TENSORRT_PROBE=true
YOLO_TENSORRT_PROBE_DEVICE=0
```

서비스 시작 시 엔진 존재 여부, SHA-256, 실제 추론 probe를 확인한다. 엄격한 `tensorrt` 모드에서는 검증 실패를 PyTorch fallback으로 숨기지 않고 서비스 시작을 실패시킨다.

배포 파일은 저장소 작업 경로를 직접 실행하지 않고 immutable release 디렉터리에 고정했다. 전환 과정에서는 환경 파일, systemd unit, 기존 override를 백업했으며 검증 실패 시 이전 릴리스로 자동 복구하도록 했다.

## 8. 결정의 한계와 다음 작업

이번 결론은 현재 사무실 데이터와 Jetson Orin Nano 환경에 한정된다.

- 다른 가정, 조도, 카메라 높이에서는 정확도가 달라질 수 있다.
- 수동 라벨의 경계 일관성을 별도 검수자가 재확인하지 않았다.
- ByteTrack ID 유지율, 그룹 중심 흔들림, 서보 진동은 이번 정확도 지표에 포함하지 않았다.
- TensorRT 또는 JetPack을 변경하면 기존 엔진의 호환성을 가정하지 않고 다시 빌드·검증해야 한다.
- 실제 전력 값은 순간 최고값이므로 전체 에너지 소비량으로 해석하지 않는다.

다음 비교에서는 실제 가정 환경과 교차·가림 장면을 늘리고, 추적 ID 전환 횟수와 화면 중심 오차를 함께 측정한다. 또한 같은 데이터와 runner로 YOLOv8n PyTorch와 TensorRT FP16을 직접 비교해 런타임 전환의 순수 성능 차이를 별도로 기록한다.

## 9. 발표용 요약

> 공개 성능이나 모델 세대만 보고 고르지 않고, 직접 만든 395장·581개 박스 데이터셋으로 Jetson에서 세 모델을 같은 TensorRT FP16 조건으로 비교했습니다. YOLO11n은 mAP가 0.6%p 높았지만 운영 임계값에서는 YOLOv8n보다 오탐과 미탐이 많았습니다. YOLO26n은 가장 빨랐지만 정확도 허용 범위를 벗어났고 교차 장면의 미탐이 컸습니다. YOLOv8n은 평균 27.1 FPS, Wall P95 39.3ms, 운영 F1 96.7%로 정확도와 실시간성 기준을 모두 만족했습니다. 그래서 모델은 YOLOv8n을 유지하고, Jetson 배포에 맞춘 TensorRT FP16 엔진으로 실행하도록 전환했습니다. 실제 앱 영상·음성, 3명 추적, 녹화까지 검증했고 서비스 재시작 없이 정상 동작했습니다.

## 10. 근거 자료

- 초기 PyTorch 비교: [`ai/model_benchmark/reports/20260731_yolo_pt_comparison/README.md`](../../ai/model_benchmark/reports/20260731_yolo_pt_comparison/README.md)
- 초기 PyTorch 정량 원본: [`benchmark-results.json`](../../ai/model_benchmark/reports/20260731_yolo_pt_comparison/benchmark-results.json)
- TensorRT FP16 정확도·실시간성 비교: [`20260802_yolo_tensorrt_fp16_accuracy/README.md`](../../ai/model_benchmark/reports/20260802_yolo_tensorrt_fp16_accuracy/README.md)
- TensorRT FP16 정량 원본: [`benchmark-results.json`](../../ai/model_benchmark/reports/20260802_yolo_tensorrt_fp16_accuracy/benchmark-results.json)
- TensorRT FP16 정적 대시보드: [`dashboard.html`](../../ai/model_benchmark/reports/20260802_yolo_tensorrt_fp16_accuracy/dashboard.html)
- TensorRT 비교 ID: `yolo-trt-fp16-395-comparison-20260802T055004Z`
- Jetson TensorRT 원본: `/home/ssafy/ai_benchmark_results/yolo-trt-fp16-395-comparison-20260802T055004Z`
- TensorRT 비교 기록 커밋: `cbadbe35dd44eba1318dd6ae77307b464851462c`
- TensorRT 운영 런타임 기능 커밋: `b481212`
- 운영 릴리스 소스 커밋: `07ab7b33304dc997c18e8658c6437d4846f10625`
- [NVIDIA TensorRT 공식 문서](https://docs.nvidia.com/deeplearning/tensorrt/latest/)
- [NVIDIA TensorRT 정확도 고려사항](https://docs.nvidia.com/deeplearning/tensorrt/latest/inference-library/accuracy-considerations.html)
- [NVIDIA TensorRT 엔진 호환성](https://docs.nvidia.com/deeplearning/tensorrt/latest/inference-library/engine-compatibility.html)
