# IoT / live / edge AI integration status

상세 작업 기록과 재현 절차는 [`JETSON_HANDOFF_2026-07-23.md`](JETSON_HANDOFF_2026-07-23.md)를 참고한다.

## 완료 및 실기 확인

- 기기 bootstrap/enrollment, 가상 등록 버튼, 앱의 코드 claim
- MQTTS 상태/명령 연결과 앱 ONLINE 표시
- 앱 시청 세션별 `START_STREAM`/`READY`/heartbeat/STOP 흐름
- SSH 로컬 포워드를 통한 동적 RTSP publish와 MediaMTX HLS 재생
- Brio 100 영상/음성 동시 라이브 재생
- 물리 카메라를 한 번만 점유하는 상시 공유 미디어 소스
- Live View와 무관하게 항상 실행되는 YOLO/ByteTrack 및 YAMNet
- 사람 중심 맞춤 방향 명령 로그 (`LEFT/RIGHT/UP/DOWN/HOLD/HOME`)
- 웃음 감지와 앞 5초 + 뒤 5초 영상/음성 파일 생성

## 진행 중

- 웃음 영상 mux 및 서버 업로드 완료 확인
- 업로드 후 앱 최근 영상 목록 반영 확인
- 실제 팬/틸트 모터 연결 및 PWM 제어
- 환경별 YAMNet 임계값 검증과 오탐 억제

## 운영 원칙

- `wj-media-source`, `wj-edge-ai-mvp`, `wj-media-tunnel`, `wj-device-agent`는 부팅 시 시작한다.
- YOLO와 YAMNet은 항상 실행한다.
- 서버로 보내는 라이브 RTSP 릴레이는 앱에 활성 시청자가 있을 때만 실행한다.
- MQTT operating credential의 client ID는 `deviceId`에 고정되므로 AI 프로세스가 별도의 동일 MQTT 연결을 만들지 않는다.
- 이벤트 영상은 MQTT가 아니라 IoT upload URL API와 object storage로 전송한다.
- 토큰, CA 개인키, SSH 개인키는 Git에 커밋하지 않는다.
