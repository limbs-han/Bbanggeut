# William James 백엔드

Spring Boot 3.5 / Java 17 기반 API 서버다. PostgreSQL(Flyway), MinIO(S3 호환), Mosquitto(MQTT)를 사용한다.

## 로컬 실행

```powershell
cd C:\higher\S15P11E201\backend
docker compose up -d
cd server
.\gradlew.bat bootRun
```

기본 API는 `http://localhost:8080`, 상태 확인은 `GET /actuator/health`다. DB 스키마는 서버 시작 시 Flyway가 V1부터 자동 적용한다.

```powershell
.\gradlew.bat test
.\gradlew.bat bootJar
```

## 구현 범위

- 사용자 가입·로그인·refresh token 회전, 이메일·IP 해시 기반 로그인 시도 제한
- 기기 claim, OWNER/MEMBER 멤버십, 이메일 초대와 멤버 요청 링크, 설정·상태·회수
- 기기 전용 credential과 IoT 영상 업로드/완료
- loopback 전용 기기 provisioning·credential 발급/교체/회수 운영 API
- 영상 목록·상세·재생·다운로드·메타데이터·비동기 삭제
- 캘린더 기간 필터, 저장 영상 통계와 업로드 실패를 포함한 원시 감지 이벤트 통계
- 로컬 편집용 원본 다운로드 URL 발급(편집 작업·결과 파일은 서버에 저장하지 않음)
- MQTT heartbeat·등록 모드·상태·라이브 이벤트 수신
- 감지 이벤트 멱등 저장과 영상 업로드 상태 연결
- 완료되지 않은 업로드의 `FAILED` 전환과 동일 이벤트 재시도
- 공유 라이브 송출 세션, 시청자 heartbeat/TTL, START·EXTEND·STOP 명령
- 사용자별 FCM 토큰 등록·해제와 초대·웃음 영상 운영체제 푸시
- 주요 접근·변경 감사 로그

API 계약은 [`../../자료/api/openapi.yaml`](../../자료/api/openapi.yaml), MQTT 계약은 [`../../자료/api/mqtt-contract.md`](../../자료/api/mqtt-contract.md)에서 관리한다.

## 필수 환경변수

실제 값은 `.env`나 배포 서버의 secret 환경 파일에 두고 Git에 커밋하지 않는다. 전체 목록은 [`.env.example`](.env.example)을 참고한다.

- `DB_URL`, `DB_USER`, `DB_PASSWORD`
- `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD`: 로그인/claim 제한과 기기 presence 저장소
- `DEVICE_PRESENCE_TTL`: heartbeat 기반 ONLINE 유지 시간, 기본 90초
- `JWT_SIGNING_KEY`: 32바이트 이상 임의 문자열
- `S3_ENDPOINT`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET`
- `MQTT_BROKER_URL`, `MQTT_CLIENT_ID`, `MQTT_USERNAME`, `MQTT_PASSWORD`, `MQTT_ENV`
- `MEDIA_BASE_URL`: 외부 앱이 접근할 HLS 기준 URL
- `DEVICE_PROVISIONING_ENABLED`, `DEVICE_PROVISIONING_ADMIN_KEY`: loopback 운영 API 활성화와 32자 이상 관리자 키
- `LOGIN_MAX_FAILURES`, `LOGIN_FAILURE_WINDOW`: 기본 5회/10분 로그인 제한
- `UPLOAD_STALE_AFTER`, `UPLOAD_SWEEP_DELAY_MS`: 중단 업로드 실패 전환 기준과 점검 주기
- `FCM_ENABLED`, `FIREBASE_PROJECT_ID`: FCM 푸시 활성화와 Firebase 프로젝트 ID
- `GOOGLE_APPLICATION_CREDENTIALS`: 서버에만 저장한 Firebase 서비스 계정 JSON의 절대 경로

FCM은 기본적으로 비활성화되어 로컬·CI에서 Google 자격 증명을 요구하지 않는다.
운영에서 서비스 계정 JSON을 `/home/ubuntu/william-james/secrets`처럼 저장소 밖의
읽기 제한 경로에 두고 위 세 환경변수를 설정하면 활성화된다. 서비스 계정 JSON과
서버 키는 저장소나 Flutter 앱에 포함하지 않는다.

## 라이브 미디어 경계

백엔드는 라이브 제어 평면을 담당한다. MQTT로 기기에 송출 시작/연장/종료를 명령하고 시청자별 단기 토큰을 발급한다. 실제 H.264/AAC ingest와 HLS remux/fan-out은 별도 미디어 서버가 담당한다.

미디어 서버는 MediaMTX를 기본 선택으로 권장한다. 송출 경로를 `live/{streamId}`로 맞추면 백엔드의 기본 재생 URL 형식은 다음과 같다.

```text
{MEDIA_BASE_URL}/{streamId}/index.m3u8?token={short-lived-token}
```

미디어 서버 또는 앞단 reverse proxy는 playlist와 segment 요청 전에 `GET /api/live/introspect?streamId={path-stream-id}&token=...`를 호출하고 204일 때만 전달해야 한다. 서버는 토큰에 서명된 stream ID와 경로의 ID를 대조한다. 미디어 포트(기본 HLS 8888)를 인터넷에 그대로 공개하지 않는다. 기기 publish 인증/ACL도 시청 토큰과 별도로 설정한다.

## EC2 배포 원칙

PEM 파일은 개발 PC의 `~/.ssh` 같은 로컬 보안 경로에만 둔다. 프로젝트 폴더나 EC2 안으로 복사하지 않는다. 저장소의 `.gitignore`는 `*.pem`, `.env`, key store를 제외한다.

초기 배포 순서는 다음과 같다.

1. SSH 22 접속이 유지되는지 확인한다.
2. Docker와 Java 17을 설치한다. FFmpeg는 서버 필수 구성 요소가 아니다.
3. PostgreSQL·MinIO·Mosquitto는 loopback 또는 내부 Docker network에만 바인딩한다.
4. secret 환경 파일을 서버에서 직접 만들고 권한을 소유자 읽기 전용으로 제한한다.
5. `./gradlew test bootJar` 후 JAR를 systemd로 실행한다.
6. Nginx/Caddy로 443만 공개하고 `/actuator/health`로 확인한다.
7. MQTT를 외부 기기에 열어야 한다면 1883 대신 TLS 8883과 기기별 인증/ACL을 사용한다.

UFW에서는 기존 SSH 세션을 유지한 채 22를 먼저 허용하고, reverse proxy가 준비된 다음 80/443을 연다. 5432, 9000, 9001, 1883, 8080, 8888은 공개하지 않는다.

## 데이터 정책 기본값

- 기기별 `retentionDays` 기본 30일
- 삭제 요청은 즉시 목록에서 숨기고 worker가 객체를 제거한 뒤 `DELETED` 확정
- 편집 결과는 앱에서 로컬로 내보내며 서버 객체·영상 행을 생성하지 않음
- 시청자 heartbeat 권장 15초, viewer TTL 45초, 마지막 활동 기준 idle 60초, edge hard lease 120초

보존 기간 자동 만료 배치와 사용자 삭제 요청의 비동기 처리가 구현되어 있다. 운영 provisioning·백업·모니터링·CI/CD 절차는 [`../../자료/docs/16_백엔드_잔여작업_구현_운영.md`](../../자료/docs/16_백엔드_잔여작업_구현_운영.md)를 따른다.
