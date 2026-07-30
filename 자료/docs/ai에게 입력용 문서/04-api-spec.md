# API 명세서 (AI/코딩 에이전트용)

> 기준: to-be 기획(MVP 2026-07-27 확정) · 코드 현황 참조 커밋 5979279
> 사람용 원본: [../사람이 읽을 문서/04-API명세서.md](../사람이%20읽을%20문서/04-API명세서.md)

ID 체계: API-01~51(REST, `API-06`은 서버 부재로 본문·부록 모두 제외) + MQTT-01~15. 배치는 MVP 7단계 순서(사람용 원본과 동일 구조). JSON 예시는 그대로 복사해 사용 가능 — 주석(`//`)은 타입/필수여부 설명이며 실제 요청 시 제거할 것.

**API-51은 `[제안]` — 구현된 FN-A38 Flutter 화면의 단말 집계를 FN-S26 서버 집계로 확장하기 위한 초안이며 미구현이다. 존재하는 API로 가정하고 연동 코드를 작성하지 말 것.**

---

## 1. 공통 사항

### 1.1 베이스 URL

- 앱: `https://i15e201.p.ssafy.io` (기본값, `String.fromEnvironment('API_BASE_URL')`, `frontend/lib/core/api_client.dart`)
- 디바이스 에이전트: `device-agent.env`의 `API_BASE_URL` (`ai/device_agent/wj_device_agent/config.py`)

### 1.2 인증 3종

| # | 방식 | 대상 경로 | 헤더/검증 | 실패 응답 | 컨트롤러 경로 |
|---|---|---|---|---|---|
| 1 | 내부 관리자 키 | `/internal/admin/**` | `X-Provisioning-Key` + loopback(127.0.0.1/::1) | 404 `RESOURCE_NOT_FOUND`(위장) | `provisioning/api/ProvisioningController.java` |
| 2 | 기기 credential | `/api/iot/**` | `Authorization: Bearer <keyId>.<secret>`(`/enrollment`만 ROLE_DEVICE_BOOTSTRAP, 나머지 ROLE_DEVICE_OPERATING) | 401 `DEVICE_AUTHENTICATION_FAILED` | `device/api/IotRegistrationController.java`, `iot/auth/DeviceCredentialController.java`, `video/api/IotVideoController.java` |
| 3 | 사용자 JWT | 나머지 전부 | `Authorization: Bearer <JWT>`(HS256, `sub`=userUUID, `sid`=세션UUID) | 401 `AUTHENTICATION_REQUIRED` / 403 `ACCESS_DENIED`·`FORBIDDEN_ROLE` | 그 외 전 컨트롤러 |

`permitAll`(인증 불필요): `POST /api/auth/signup`, `POST /api/auth/login`, `POST /api/auth/refresh`, `GET /api/membership-request-links/*/open`, `GET /actuator/health`, `GET /api/live/introspect`.

### 1.3 공통 에러 형식

전역 예외(모든 엔드포인트 공통, 각 API별 표에는 비즈니스 에러 코드만 기재):

```json
// 422 VALIDATION_FAILED (Bean Validation 실패)
// 422 MALFORMED_JSON (JSON 파싱 실패)
// 422 MISSING_REQUIRED_HEADER
// 500 INTERNAL_SERVER_ERROR
{
  "code": "string",
  "message": "string",
  "requestId": "string",
  "fieldErrors": { "field": "reason" }   // null이면 응답에서 생략(@JsonInclude(NON_NULL))
}
```
소스: `common/api/ErrorResponse.java`, `common/api/ApiException.java`, `common/web/GlobalExceptionHandler.java`.

---

## 2. MVP ① 회원가입 / 로그인

컨트롤러: `auth/api/AuthController.java` · Base `/api/auth`

#### API-01 `POST /api/auth/signup`
- 인증: 공개(permitAll)
```json
{
  "email": "user@example.com",     // required, @Email @Size<=320
  "password": "string",            // required, @Size 10~72
  "displayName": "string"          // required, @Size<=60
}
```
- 응답 201:
```json
{
  "accessToken": "string",
  "refreshToken": "string",
  "tokenType": "Bearer",
  "expiresIn": 900,
  "user": { "id": "uuid", "email": "string", "displayName": "string" }
}
```
- 에러: 409 `EMAIL_ALREADY_EXISTS`
- 프런트: `AuthScreen.submit`(`frontend/lib/ui/auth_screen.dart`)

#### API-02 `POST /api/auth/login`
- 인증: 공개(permitAll)
```json
{ "email": "user@example.com", "password": "string" }
```
- 응답 200: API-01과 동일 스키마(`AuthTokenResponse`)
- 에러: 401 `INVALID_CREDENTIALS`, 429 `LOGIN_RATE_LIMITED`(이메일+IP 지문 기준 5회/10분 초과)

#### API-03 `POST /api/auth/refresh` (내부 호출: `api_client.dart._tryRefresh()` 401 인터셉터)
- 인증: 공개(permitAll)
```json
{ "refreshToken": "string" }   // required, @Size 32~2048
```
- 응답 200: `AuthTokenResponse`
- 에러: 401 `INVALID_REFRESH_TOKEN`
- 비고: 액세스 토큰 TTL 15분, 리프레시 토큰 TTL 14일(사용할 때마다 재발급, rotate-on-use). 리프레시 토큰은 해시로만 저장.

---

## 3. MVP ② 기기 등록

### API-08 `POST /api/devices/claim`
- 인증: 사용자 JWT
```json
{
  "registrationCode": "string",   // required, @Size 8~12
  "name": "string",                // optional, @Size 1~80, 공백만 불가
  "vaultId": "uuid"                // optional, 기존 금고에 연결할 때 지정
}
```
- 응답 201:
```json
{
  "id": "uuid", "name": "string", "model": "string", "status": "string",
  "myRole": "OWNER", "retentionDays": 30, "lastSeenAt": "2026-07-27T00:00:00Z",
  "serialNumber": "string", "firmwareVersion": "string", "claimedAt": "2026-07-27T00:00:00Z"
}
```
- 에러: 429 `CLAIM_RATE_LIMITED`(5회/10분), 409 `DEVICE_CLAIM_REJECTED`
- 비고: `vaultId` 생략 시 새 추억 금고와 요청 사용자의 OWNER 멤버십을 만든다. 지정 시 해당 금고의 OWNER 권한을 확인하고 활성 Device Binding을 생성한다. 물리 기기의 연결 이력은 generation별로 보존된다.

### Vault API `GET/POST /api/vaults`
- 인증: 사용자 JWT
- `GET /api/vaults`: `vault_memberships` 기준 참여 금고와 활성 연결 기기 목록 조회
- `GET /api/vaults/{vaultId}`: 접근권한을 검증한 추억 금고 단건 조회
- `POST /api/vaults`: 물리 기기 없이 독립적인 추억 금고 생성
- 응답 핵심 필드: `id`, `name`, `status`, `myRole`, `retentionDays`, `subscriptionActive`, `devices[]`
- 비고: `devices`가 빈 배열이어도 금고는 유효하다. 영상·구독·가족 권한은 물리 기기가 아니라 금고에 귀속된다. 연결 기기의 온라인 상태는 Redis presence를 합성하고 Redis 장애 시 PostgreSQL 값으로 폴백한다.

### API-43 `POST /api/iot/registration-codes`
- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING) / 요청 본문 없음(`DevicePrincipal`만 사용)
- 컨트롤러: `device/api/IotRegistrationController.java`
- 응답 200:
```json
{ "registrationCode": "string", "expiresAt": "2026-07-27T00:02:00Z" }
```
- 에러: 409 `DEVICE_ALREADY_CLAIMED`
- 비고: TTL 120초. 코드는 해시로만 저장(평문 미보관), 코드 중복 시 최대 5회 재생성.
- 호출부: `ai/device_agent/wj_device_agent/provision.py`(`registration-code` 서브커맨드)

### API-44 `POST /api/iot/enrollment`
- 인증: 기기 credential(Bearer, ROLE_DEVICE_BOOTSTRAP) / 요청 본문 없음
- 컨트롤러: `iot/auth/DeviceCredentialController.java`
- 응답 200:
```json
{
  "deviceId": "uuid", "serialNumber": "string", "keyId": "string",
  "bearerToken": "{keyId}.{secret}", "purpose": "BOOTSTRAP|OPERATING",
  "expiresAt": "2026-08-26T00:00:00Z", "mqttUsername": null
}
```
- 에러: 404 `RESOURCE_NOT_FOUND`, 401 `DEVICE_CREDENTIAL_STALE`, 403 `DEVICE_CREDENTIAL_PURPOSE_INVALID`
- 비고: 1회용 BOOTSTRAP(TTL 15분) 토큰을 OPERATING(TTL 30일) 자격증명으로 교환.
- 호출부: `DeviceApi.enroll`(`ai/device_agent/wj_device_agent/provision.py`)

### API-45 `POST /api/iot/credentials/rotate`
- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING) / 요청 본문 없음
- 응답 200: API-44와 동일 스키마 / 에러: 동일
- 비고: 기기당 활성(ACTIVE) 자격증명은 1개만 유지, 만료 전 회전.
- 호출부: `DeviceApi.rotate`(`provision.py`)

### API-07 `GET /api/devices`
- 인증: 사용자 JWT
- 응답 200:
```json
[
  {
    "id": "uuid", "name": "string", "model": "string",
    "status": "UNCLAIMED|ONLINE|OFFLINE|REVOKED",
    "myRole": "OWNER|EDITOR|VIEWER", "retentionDays": 30,
    "lastSeenAt": "2026-07-27T00:00:00Z"
  }
]
```
- 비고: 호출자의 활성 멤버십 기준으로 접근 가능한 기기만 필터링된다.

### API-11 `GET /api/devices/{deviceId}/status`
- 인증: 사용자 JWT
- 응답 200:
```json
{
  "deviceId": "uuid", "status": "string",
  "recording": false,            // 최근 MQTT-05 heartbeat 보고값
  "uploadQueueDepth": 0,          // 최근 MQTT-05 heartbeat 보고값
  "bufferSeconds": null,          // nullable
  "personCount": null,            // nullable
  "checkedAt": "2026-07-27T00:00:00Z"
}
```
- 에러: 404 `RESOURCE_NOT_FOUND`

---

## 4. MVP ③ 홈에서 라이브 스트리밍 시청

컨트롤러: `stream/api/StreamController.java`, `stream/api/LiveIntrospectionController.java`

### API-35 `POST /api/devices/{deviceId}/stream-sessions`
- 인증: 사용자 JWT
- 응답 202:
```json
{
  "sessionId": "uuid", "streamId": "uuid", "deviceId": "uuid",
  "status": "PENDING|READY|FAILED|CLOSED|EXPIRED",
  "playUrl": null,                     // READY일 때만 값 존재, HLS 폴백 URL
  "whepUrl": null,                     // READY일 때만 값 존재, WebRTC/WHEP 우선 URL
  "heartbeatIntervalSeconds": 15,
  "viewerExpiresAt": "2026-07-27T00:00:45Z",
  "edgeHardExpiresAt": "2026-07-27T00:02:00Z",
  "failureCode": null,
  "createdAt": "2026-07-27T00:00:00Z"
}
```
- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `DEVICE_OFFLINE`(기기 오프라인이면 세션 생성 거부)
- 실사용: `EmbeddedLivePlayer`와 전체화면 라이브. `WhepPlayerController`로 WHEP 우선 연결 후 HLS 폴백

### API-36 `GET /api/stream-sessions/{sessionId}`
- 인증: 사용자 JWT
- 응답 200: API-35와 동일 스키마 / 에러: 404
- 비고: 앱은 세션 생성 후 2초 간격으로 상태를 폴링해 `READY`가 되면 재생을 시작한다.

### API-37 `DELETE /api/stream-sessions/{sessionId}`
- 인증: 사용자 JWT / 응답 204 / 에러: 404 `RESOURCE_NOT_FOUND`

### API-38 `POST /api/stream-sessions/{sessionId}/heartbeat`
- 인증: 사용자 JWT / 응답 204 / 에러: 404
- 비고: `heartbeatIntervalSeconds`(기본 15초) 간격으로 호출해 유휴 타임아웃(60초)을 방지한다.

### MQTT-01 `{base}/devices/{deviceId}/commands` — 발행(백엔드→기기), QoS1
```json
{
  "schemaVersion": "2.0", "requestId": "uuid", "deviceId": "uuid",
  "type": "START_STREAM",
  "issuedAt": "2026-07-27T00:00:00Z", "expiresAt": "2026-07-27T00:00:15Z",
  "payload": {
    "sessionId": "uuid", "streamId": "uuid",
    "profile": "LIVE_720P_H264_AAC", "segmentDurationSeconds": 2,
    "hardExpiresAt": "2026-07-27T00:02:00Z"
  }
}
```
- `type=EXTEND_STREAM.payload`: `{streamId, hardExpiresAt}` / `type=STOP_STREAM.payload`: `{streamId, reason}`
- 발행: `stream/application/StreamCommandPublisher.java`, `StreamService.java`, `iot/mqtt/PahoMqttGateway.java` / 구독: `ai/device_agent/wj_device_agent/agent.py:103`

### MQTT-04 `{base}/devices/+/stream/events` — 구독(기기→백엔드), QoS1
```json
{
  "schemaVersion": "2.0", "eventId": "uuid", "requestId": "uuid", "deviceId": "uuid",
  "streamId": "uuid", "type": "STREAM_READY",
  "occurredAt": "2026-07-27T00:00:00Z", "hardExpiresAt": "2026-07-27T00:02:00Z",
  "errorCode": null, "sessionId": "uuid"
}
```
- `type`: `STREAM_STARTING|STREAM_READY|STREAM_ERROR|STREAM_HARD_EXPIRED|STREAM_STOPPED`
- 발행: `agent.py:264-285` / 구독: `iot/telemetry/MqttInboundHandler.java`(streamEvent()), `stream/application/StreamEventService.java`

### 미디어 경로

- **RTSPS publish(Jetson→MediaMTX)**: `rtsps://{username}:{password}@{host}:8322/live/{stream_id}` — 자격증명 포함, 경로 고정, TLS CA 필수. ffmpeg: `-f v4l2` 입력→`-c:v libx264 -preset ultrafast -tune zerolatency`(기본 2500kbps)→`-f rtsp -rtsp_transport tcp`. 소스: `ai/device_agent/wj_device_agent/stream.py`, `configure_media.py`, `config.py`
- **WebRTC/WHEP 우선(앱)**: `whepUrl`에 recv-only SDP offer를 `POST application/sdp`, MediaMTX answer 적용. 별도 WebSocket signaling 없음. 종료 시 WHEP `Location` URI에 DELETE
- **HLS 폴백(앱)**: WHEP/ICE 실패 또는 `whepUrl` 부재 시 `playUrl` 사용. `{media-base-url}/{streamId}/index.m3u8?token={liveToken}`
- **운영 경로**: Nginx HTTPS 443 `/webrtc/.../whep`→MediaMTX loopback 8889, WebRTC media/ICE UDP 8189. 8889 직접 외부 노출 금지
- **API-34** `GET /api/live/introspect`(공개, `token`/`streamId` 서명검증→204/401) — Nginx가 WHEP/HLS 접근 인가에 사용. 앱/젯슨 직접 호출 금지
- 기기당 스트림 1개만 유지(`DEVICE_BUSY`로 거부). `EXTEND_STREAM`은 동일 `streamId`의 하드 만료 시각만 갱신.

---

## 5. MVP ④ 이벤트(웃음) 감지 영상 확인

컨트롤러: `video/api/IotVideoController.java`(`/api/iot/videos`, 기기credential), `video/api/VideoController.java`(`/api/videos`, 사용자JWT)

### 이벤트 업로드 흐름 (젯슨 → 서버)
1. 젯슨(YAMNet)이 웃음 트리거를 감지하면 전후 구간 클립을 로컬에 생성한다.
2. **API-25**로 업로드 URL을 발급받는다(`Idempotency-Key` = `sourceEventId`).
3. presigned URL로 MinIO에 `PUT` 업로드(TTL 15분, 500MiB 초과 거부).
4. **API-26**으로 업로드 완료 통보 → 상태 `READY` 전환.
5. 앱은 API-27(목록)·API-31(재생)로 클립을 확인한다.

### API-25 `POST /api/iot/videos/upload-url`
- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING)
- Header: `Idempotency-Key`(필수, `sourceEventId`와 동일)
```json
{
  "sourceEventId": "uuid-string",          // required, @Size<=100
  "triggerType": "LAUGHTER",               // required, "LAUGHTER|WAKE_WORD|TOUCH|MANUAL"
  "title": "string",                        // required, @Size<=120
  "capturedStartAt": "2026-07-27T00:00:00Z",// required
  "capturedEndAt": "2026-07-27T00:01:00Z",  // required
  "durationMs": 60000,                      // required, >=1
  "contentType": "video/mp4",                // required
  "sizeBytes": 1048576,                      // required, >=1, 최대 500MiB
  "checksumSha256": "64자hex"                // required, [0-9a-f]{64}
}
```
- 응답 200:
```json
{
  "videoId": "uuid", "alreadyCompleted": false,
  "uploadUrl": "https://minio/.../presigned-put", "method": "PUT",
  "requiredHeaders": { "x-amz-meta-sha256": "string" },
  "expiresAt": "2026-07-27T00:15:00Z"
}
```
- 에러: 413 `VIDEO_TOO_LARGE`, 422 `VALIDATION_FAILED`, 409 `DEVICE_NOT_CLAIMED`, 409 `VIDEO_STATE_CONFLICT`, 409 `IDEMPOTENCY_KEY_MISMATCH`, 409 `IDEMPOTENCY_CONFLICT`, 503 `OBJECT_STORAGE_UNAVAILABLE`
- 호출부: `ai/yolo/laughter_clip_uploader.py`, `ai/yolo/segment_clip_uploader.py`

### API-26 `POST /api/iot/videos/complete`
- 인증: 기기 credential(Bearer) / Header: `Idempotency-Key`(필수)
```json
{ "videoId": "uuid", "objectETag": "string" }   // objectETag optional, @Size<=200
```
- 응답 200: `VideoResponse`(아래 스키마) / 에러: 404, 409 `VIDEO_STATE_CONFLICT`, 409 `IDEMPOTENCY_KEY_MISMATCH`, 409 `UPLOAD_INTEGRITY_MISMATCH`, 503

### API-27 `GET /api/videos`
- 인증: 사용자 JWT
- Query: `deviceId` 또는 `vaultId` 중 정확히 하나(필수, uuid), `triggerType?`, `from?`(Instant), `to?`(Instant), `cursor?`, `size?`(기본20, 1~100)
- 응답 200:
```json
{
  "items": [ /* VideoResponse[] — 아래 스키마 */ ],
  "nextCursor": "string", "hasNext": false
}
```
- 에러: 422 `VALIDATION_FAILED`(조회 기준 중복/누락 포함), 404, 422 `INVALID_CURSOR`

`VideoResponse` 스키마(API-26/27/28/29 공통):
```json
{
  "id": "uuid", "deviceId": "uuid",
  "sourceType": "IOT_CAPTURE|USER_UPLOAD|EDIT_OUTPUT",
  "triggerType": "LAUGHTER|WAKE_WORD|TOUCH|MANUAL|USER_UPLOAD|EDIT",
  "sourceEventId": null, "title": "string", "description": null,
  "contentType": "video/mp4", "sizeBytes": 1048576, "checksumSha256": "string",
  "durationMs": 60000, "capturedStartAt": "2026-07-27T00:00:00Z", "capturedEndAt": "2026-07-27T00:01:00Z",
  "status": "UPLOADING|PROCESSING|READY|FAILED|DELETING|DELETED",
  "isFavorite": false,
  "thumbnailUrl": null,   // ⚠️ 코드상 항상 null(썸네일 생성 로직 존재 여부 미확인)
  "createdAt": "2026-07-27T00:00:00Z"
}
```

### API-31 `POST /api/videos/{videoId}/play-url`
- 인증: 사용자 JWT
- 응답 200:
```json
{ "url": "https://minio/.../presigned-get", "expiresAt": "2026-07-27T00:05:00Z" }
```
- 에러: 404, 409 `VIDEO_NOT_READY`(READY가 아니면 발급 거부), 503 `OBJECT_STORAGE_UNAVAILABLE`

### MinIO 서명 URL 공통 사항
- 업로드(PUT, API-25): TTL 15분, `x-amz-meta-sha256` 헤더 포함
- 재생/다운로드(GET, API-31/32): TTL 5분, 다운로드는 `response-content-disposition=attachment` 쿼리 추가
- 스토리지 실패 시 503 `OBJECT_STORAGE_UNAVAILABLE`, 업로드 완료(API-26) 시 객체 미존재는 409 `UPLOAD_OBJECT_NOT_FOUND`

---

## 6. MVP ⑤ 영상 편집

**별도 서버 API는 필요하지 않다** — 편집은 전적으로 폰에서 이루어지며(Banuba, Android 전용), 원본 다운로드는 7절과 동일한 **API-32**(다운로드 URL)를 재사용한다.

---

## 7. MVP ⑥ 편집 영상 다운로드

### API-32 `POST /api/videos/{videoId}/download-url`
- 인증: 사용자 JWT
- 응답 200: API-31과 동일 스키마(`response-content-disposition=attachment` 쿼리가 추가된 URL)
- 에러: 404, 409 `VIDEO_NOT_READY`, 503 `OBJECT_STORAGE_UNAVAILABLE`
- 비고: 재생 URL과 동일 TTL(5분). 앱은 이 URL을 외부 브라우저/공유 시트로 실행하며, 편집 결과물(Banuba 산출물)은 앱 로컬(`edited_videos/`)에 저장 후 공유 시트로 SNS/메신저에 전달(서버 API 불요).

---

## 8. MVP ⑦ 통계 / 리포트

### API-27 `GET /api/videos` — 캘린더 범위 조회로 재사용
- 스키마는 5절의 API-27과 완전히 동일. `deviceId`+월 범위(`from`~`to`)로 호출, 응답 `items`를 날짜별로 집계해 표시.

### API-33 `GET /api/devices/{deviceId}/stats`
- 인증: 사용자 JWT / Query: `from?`,`to?`(LocalDate), `timeZone?`
- 컨트롤러: `video/api/VideoStatsController.java`
- 응답 200:
```json
{
  "deviceId": "uuid", "from": "2026-07-01", "to": "2026-07-27", "timeZone": "Asia/Seoul",
  "totalCount": 42,
  "byTriggerType": [ { "name": "LAUGHTER", "count": 30 } ],
  "dailyCounts": [ { "date": "2026-07-27", "count": 3 } ],
  "peakWeekday": { "name": "SATURDAY", "count": 10 },
  "peakHour": { "name": "20", "count": 8 }
}
```
- 에러: 404, 422 `VALIDATION_FAILED`

### API-51 `GET /api/devices/{deviceId}/laugh-report` **[제안·미구현]**

> 구현된 FN-A38 Flutter 화면의 단말 집계를 FN-S26 서버 집계로 확장하기 위한 초안이다. **API-51 서버 코드 없음.** 기존 API-33(`VideoStatsService`)·API-46(`EventStatsService`)의 집계 로직과 `device_events` 데이터를 확장 기반으로 검토할 수 있다. 베스트 클립의 실제 재생 URL 발급은 기존 **API-31을 재사용**(이 API 응답 자체는 재생 URL을 담지 않음).

- 인증: 사용자 JWT **[제안]**
- Query **[제안]**:
```json
{
  "period": "weekly",       // required, "weekly|monthly"
  "anchor": "2026-07-27",   // optional(기본값 오늘), LocalDate — weekly면 해당 주(월요일 시작), monthly면 해당 월 전체
  "timeZone": "Asia/Seoul",  // optional(기본값 기기 타임존)
  "bestClipLimit": 5         // optional(기본 5, 1~20)
}
```
- 응답 200 `LaughReportResponse` **[제안, 미구현]**:
```json
{
  "deviceId": "uuid",
  "period": "weekly",
  "rangeFrom": "2026-07-21", "rangeTo": "2026-07-27",
  "summary": {
    "laughCount": 12,
    "previousLaughCount": 9,
    "changeRate": 33.3          // %, 직전 값이 0이면 null
  },
  "hourlyDistribution": [ { "hour": 0, "count": 0 } /* 0~23시 24슬롯 */ ],
  "bestClips": [
    {
      "videoId": "uuid",        // API-31 재생 URL 발급 시 사용
      "title": "string",
      "occurredAt": "2026-07-27T20:00:00Z",
      "durationMs": 60000,       // nullable
      "thumbnailUrl": null       // nullable
    }
  ]
}
```
- 에러(제안) **[제안]**: 404 `RESOURCE_NOT_FOUND`, 422 `VALIDATION_FAILED`(period 미지원/anchor 형식 오류/bestClipLimit 범위 밖)
- 비고: 베스트 클립 탭 시 `bestClips[].videoId`로 **API-31**을 호출해 서명 재생 URL을 새로 발급받는다. 정렬 기준(웃음 트리거 강도/최신순 등)·베스트 클립 개수는 상세 설계 시 확정 필요.

---

## 9. 가족 공유 API

컨트롤러: `invitation/api/InvitationController.java` · Base `/api`

### API-14 `POST /api/devices/{deviceId}/invitations`
- 인증: 사용자 JWT(OWNER)
```json
{
  "email": "user@example.com",           // required, @Email @Size<=320
  "role": "EDITOR",                       // required, "EDITOR"|"VIEWER"
  "membershipRequestToken": "string"      // optional, @Size<=200
}
```
- 응답 201:
```json
{
  "id": "uuid", "deviceId": "uuid", "deviceName": "string",
  "inviteeEmail": "string", "role": "EDITOR|VIEWER",
  "inviter": { "id": "uuid", "email": "string", "displayName": "string" },
  "status": "PENDING|ACCEPTED|DECLINED|EXPIRED|REVOKED",
  "expiresAt": "2026-08-03T00:00:00Z", "createdAt": "2026-07-27T00:00:00Z"
}
```
- 에러: 403 `FORBIDDEN_ROLE`, 422 `VALIDATION_FAILED`, 409 `ALREADY_DEVICE_MEMBER`, 409 `INVITATION_PENDING`, 409 `MEMBERSHIP_REQUEST_EMAIL_MISMATCH`, 404 `MEMBERSHIP_REQUEST_NOT_FOUND`
- 비고: 초대 유효기간 7일.

### API-15 `POST /api/membership-request-links`
- 인증: 사용자 JWT / 요청 없음
- 응답 201:
```json
{ "token": "string", "expiresAt": "2026-07-28T00:00:00Z" }
```
- 비고: 요청자당 활성 링크 1개만 유지된다.

### API-16 `GET /api/membership-request-links/{token}`
- 인증: 사용자 JWT
- 응답 200:
```json
{ "email": "string", "displayName": "string", "expiresAt": "2026-07-28T00:00:00Z" }
```
- 에러: 403 `OWNER_MEMBERSHIP_REQUIRED`, 404 `MEMBERSHIP_REQUEST_NOT_FOUND`

### API-17 `GET /api/membership-request-links/{token}/open`
- 인증: 공개(permitAll), `token` 정규식 `[A-Za-z0-9_-]{43}`
- 응답: 302 Redirect(`Location: bbanggeut://membership-request/{token}`, 본문 없음) / 에러: 형식불일치 404(본문없음)
- 비고: 이메일/공유 링크로 외부 브라우저가 열고, 앱은 리다이렉트 결과인 딥링크만 수신한다(앱이 직접 호출하지 않음).

### API-18 `GET /api/devices/{deviceId}/invitations`
- 인증: 사용자 JWT(OWNER) / 응답 200: `List<InvitationResponse>`(API-14 스키마) / 에러: 403, 404

### API-19 `DELETE /api/devices/{deviceId}/invitations/{invitationId}`
- 인증: 사용자 JWT(OWNER) / 응답 204 / 에러: 403 `FORBIDDEN_ROLE`, 404, 409 `INVITATION_NOT_PENDING`
- 비고: PENDING 상태의 초대만 취소 가능.

### API-20 `GET /api/invitations`
- 인증: 사용자 JWT / 응답 200: `List<InvitationResponse>`

### API-21 `POST /api/invitations/{invitationId}/accept`
- 인증: 사용자 JWT
- 응답 200:
```json
{
  "id": "uuid", "deviceId": "uuid",
  "user": { "id": "uuid", "email": "string", "displayName": "string" },
  "role": "EDITOR|VIEWER", "status": "ACTIVE|REVOKED", "joinedAt": "2026-07-27T00:00:00Z"
}
```
- 에러: 404, 409 `INVITATION_EXPIRED`, 409 `INVITATION_NOT_PENDING`

### API-22 `POST /api/invitations/{invitationId}/decline`
- 인증: 사용자 JWT / 응답 204 / 에러: 404, 409 `INVITATION_NOT_PENDING`

### API-23 `GET /api/devices/{deviceId}/members`
- 인증: 사용자 JWT(멤버) / 응답 200: `List<DeviceMemberResponse>`(API-21 스키마) / 에러: 404

### API-24 `DELETE /api/devices/{deviceId}/members/{membershipId}`
- 인증: 사용자 JWT(OWNER) / 응답 204 / 에러: 403 `FORBIDDEN_ROLE`, 404, 409 `OWNER_CANNOT_BE_REVOKED`, 409 `MEMBERSHIP_NOT_ACTIVE`
- 비고: OWNER는 추방 불가, 이미 비활성인 멤버십은 재추방 불가.

---

## 10. 기기·세션 유지에 필요한 공통 MQTT

토픽 베이스: `${app.mqtt.environment}/wj/v2`(예: `local/wj/v2`, `prod/wj/v2`), 브로커: Mosquitto + `dynamic-security`. MQTT-01(commands)·MQTT-04(stream/events)는 4절에서 다뤘으므로 여기서는 기기 상태·하트비트·등록·이벤트 등 나머지 `wj/v2` 토픽만 정리한다.

> **v2 마이그레이션**: 토픽 루트 `wj/v1`→`wj/v2`, `schemaVersion` `1.0`→`2.0`. 백엔드는 `2.0`이 아닌 payload를 조용히 폐기한다. 기존 기기 ACL은 백엔드 시작 시 `iot/mqtt/MqttTopicAclMigrationWorker.java`가 v2로 자동 이관.

#### MQTT-02 `{base}/devices/+/status` — 구독(기기→백엔드), QoS1
```json
{
  "schemaVersion": "2.0", "deviceId": "uuid", "state": "ONLINE",
  "reason": "BOOT_COMPLETED",
  "firmwareVersion": "string", "occurredAt": "2026-07-27T00:00:00Z"
}
```
- `state`: `ONLINE|OFFLINE`, `reason`: `BOOT_COMPLETED|CONNECTION_LOST|SERVICE_STOPPED`
- 백엔드는 `state`/`firmwareVersion`만 읽음 — `reason`/`occurredAt`은 파싱하지 않고 버려짐(에러 아님)
- 발행: `agent.py:71-76(will_set),92,104` / 구독: `iot/telemetry/MqttInboundHandler.java:105-111`

#### MQTT-03 `{base}/devices/+/commands/ack` — 구독(기기→백엔드), QoS1
```json
{
  "schemaVersion": "2.0", "requestId": "uuid", "deviceId": "uuid",
  "status": "ACCEPTED",
  "errorCode": null, "message": null, "occurredAt": "2026-07-27T00:00:00Z",
  "streamId": "uuid", "sessionId": "uuid"
}
```
- `status`: `ACCEPTED|SUCCEEDED|FAILED|REJECTED|EXPIRED`. 백엔드는 `requestId`/`status`만 로그로 남김.
- 발행: `agent.py:133,237-262` / 구독: `MqttInboundHandler.java`(commandAck())

#### MQTT-05 `{base}/devices/+/heartbeat` — 구독(기기→백엔드), QoS0
```json
{
  "schemaVersion": "2.0", "deviceId": "uuid", "sentAt": "2026-07-27T00:00:00Z",
  "uptimeSeconds": 3600,
  "recording": false,          // 항상 false 고정값(스텁)
  "uploadQueueDepth": 0,        // 항상 0 고정값(스텁)
  "clockUnsynced": false,       // 항상 false 고정값(스텁)
  "firmwareVersion": "string",
  "nodes": [ { "nodeId": "string", "online": true } ],
  "streaming": false
}
```
- 30초 주기. 서버는 전체 heartbeat payload를 Redis `presence:device:{deviceId}`에 90초 TTL로 저장하고 API-07/11·금고 목록·라이브 시작 판정에 반영한다. TTL 만료는 OFFLINE이며 Redis 장애 시 PostgreSQL heartbeat 기록으로 폴백한다.
- 발행: `agent.py:211-225` / 구독: `MqttInboundHandler.java`(heartbeat())

#### MQTT-06 `{base}/devices/+/registration` — 구독(설계상, 실제 발행자 없음), QoS1
```json
{ "schemaVersion": "2.0", "deviceId": "uuid", "mode": "ENABLED", "expiresAt": "2026-07-27T00:05:00Z" }
```
- 백엔드 핸들러는 존재하나 기기 발행 코드 없음 — 등록코드 발급은 API-43(HTTP)로만 동작.
- 구독만: `MqttInboundHandler.java:90-103` / 발행: 없음

#### MQTT-07 `{base}/devices/+/events` — 구독(설계상, 실제 발행자 없음), QoS1
```json
{
  "schemaVersion": "2.0", "deviceId": "uuid", "eventId": "uuid",
  "type": "LAUGHTER",
  "occurredAt": "2026-07-27T00:00:00Z",
  "confidence": 0.9,
  "localClip": { "state": "SEGMENTS_LOCKED", "beforeMs": 60000, "afterMs": 60000, "mergeWindowMs": 30000 },
  "source": { "nodeId": "string", "component": "YAMNET", "modelVersion": "string" }
}
```
- 웃음감지→업로드는 이 토픽 없이 API-25/26(HTTP)만으로 동작, `device_events` 테이블은 사실상 미사용.
- 구독만: `MqttInboundHandler.java`(detectionEvent()), `iot/event/DeviceEventService.java` / 발행: 없음

#### MQTT-08 `$CONTROL/dynamic-security/v1` — 발행(백엔드→브로커), QoS1
```json
{ "commands": [ { "command": "createClient", "...": "..." } ] }
```
- 소스: `iot/mqtt/PahoMqttGateway.java`

#### MQTT-09 `$CONTROL/dynamic-security/v1/response` — 구독(브로커→백엔드), QoS1
- 페이로드: dynsec 커맨드 응답(스키마 비공개) / 소스: `iot/mqtt/PahoMqttGateway.java`

기기별 MQTT 계정 ACL은 발행 권한을 `status,heartbeat,registration,events,stream/events,commands/ack`에, 구독 권한을 `commands`에만 부여한다 — 기기는 `wj/v2` 네임스페이스 밖(`homecam/v2`)으로는 이 ACL 체계가 적용되지 않는다(12절 참고).

---

## 11. 부록 A: 확장 API

MVP 7단계·가족 공유 밖이지만 API 자체는 존재하는 항목이다. ID·메서드·경로·용도만 한 줄로 축약했다.

| ID | 메서드/경로 | 용도(한 줄) |
|---|---|---|
| API-04 | `POST /api/auth/logout` | 로그아웃(세션 단위 무효화) |
| API-05 | `DELETE /api/auth/me` | 회원 탈퇴(소유 기기 있으면 거부, 409 `OWNER_MEMBERSHIP_EXISTS`) |
| API-09 | `GET /api/devices/{deviceId}` | 기기 단건 조회(서버 구현·클라이언트 미사용) |
| API-10 | `PATCH /api/devices/{deviceId}` | 기기 이름/보관기간 변경(OWNER) |
| API-12 | `POST /api/devices/{deviceId}/transfer-ownership` | 기기 소유권 이전 |
| API-13 | `DELETE /api/devices/{deviceId}` | 기기 해제 |
| API-28 | `GET /api/videos/{videoId}` | 영상 단건 상세 조회 |
| API-29 | `PATCH /api/videos/{videoId}` | 영상 메타데이터(제목/메모/즐겨찾기) 수정 |
| API-30 | `DELETE /api/videos/{videoId}` | 영상 삭제(OWNER, 비동기 202) |
| API-39 | `GET /api/devices/{deviceId}/subscription` | 구독 상태 조회 |
| API-40 | `PUT /api/devices/{deviceId}/subscription` | 구독 활성화 |
| API-41 | `DELETE /api/devices/{deviceId}/subscription` | 구독 해지 |
| API-42 | `GET /api/devices/{deviceId}/home-summary` | 홈 요약 카드 집계 |
| API-46 | `GET /api/devices/{deviceId}/event-stats` | 이벤트 전용 통계(서버 구현·클라이언트 미사용, 현재는 API-33만 사용) |
| API-47 | `POST /internal/admin/devices` | (내부 관리자 키) 기기 프로비저닝 |
| API-48 | `POST /internal/admin/devices/{deviceId}/credentials/rotate` | (내부 관리자 키) 자격증명 강제 회전 |
| API-49 | `DELETE /internal/admin/devices/{deviceId}/credentials` | (내부 관리자 키) 자격증명 폐기 |
| API-50 | `GET /api/devices/{deviceId}/access-logs` | 접근 기록 커서 조회 |

---

## 12. 부록 A-2: 실험 MQTT(`homecam/v2`, 6개)

운영 배포 스크립트가 `MQTT_HOST=`(빈 값)로 넘겨 코드 경로 자체가 비활성화된 실험 단계 산출물이다(YOLO 팬틸트 추적·이벤트 퓨전용). `wj/v2` ACL 체계 밖이며 백엔드는 전혀 구독하지 않는다. **에이전트는 이 6개를 운영 중인 파이프라인으로 가정하지 말 것.**

| ID | 토픽(접미사) | 용도(한 줄) | 소스 |
|---|---|---|---|
| MQTT-10 | `homecam/v2/{device_id}/ai/vision/state` | YOLO 비전 상태 발행(추적 대상/좌표) | `ai/yolo/vision_mqtt_publisher.py:31`, `yolov8_autoframe_jetson.py:82-97` |
| MQTT-11 | `homecam/v2/{device_id}/control/framing/target` | 팬틸트 프레이밍 목표값 발행(구독자 없음) | `vision_mqtt_publisher.py:126-131` |
| MQTT-12 | `homecam/v2/{device_id}/ai/vision/status` | YOLO 컴포넌트 온/오프라인(LWT) | `vision_mqtt_publisher.py:35,47-54,92-99` |
| MQTT-13 | `homecam/v2/{device_id}/ai/laughter/detected` | YAMNet 웃음 감지 이벤트(실험 경로, 운영은 API-25/26 HTTP로 대체) | `ai/yamnet/mqtt_event_publisher.py:36,113-154` |
| MQTT-14 | `homecam/v2/{device_id}/ai/status` | YAMNet 컴포넌트 온/오프라인(LWT) | `mqtt_event_publisher.py:38` |
| MQTT-15 | `homecam/v2/{device_id}/events/memory-candidate` | 웃음+비전 컨텍스트 퓨전 결과 발행 | `ai/yolo/event_fusion_service.py:67-120,170-243` |

---

## 13. 부록 B: 구현 현황

| # | MVP 단계 | 상태 | 비고 |
|---|---|---|---|
| 1 | 회원가입 / 로그인 | 구현됨 | API-01~03 전체 동작 |
| 2 | 기기 등록 | 구현됨 | API-08, 43~45, 07, 11 포함 전체 동작 |
| 3 | 홈에서 라이브 스트리밍 시청 | 구현됨 | API-34~38, MQTT-01/04, RTSPS→WHEP/WebRTC 우선·HLS 폴백 |
| 4 | 이벤트(웃음) 감지 영상 확인 | 구현됨 | API-25~27, 31 포함 전체 동작 |
| 5 | 영상 편집 | 구현됨 | 서버 API 불요(로컬 편집) |
| 6 | 편집 영상 다운로드 | 구현됨 | API-32 |
| 7 | 통계 / 리포트 | 부분 구현 | 기존 API-27·33과 FN-A38 Flutter 단말 집계 구현. **API-51 서버 집계는 미구현** |
| 가족 공유 | API-14~24 | 구현됨 | 초대/수락/거절/구성원 관리 전체 동작 |

MVP 7단계의 신규 API 중 **API-51 서버 집계는 미구현**이다. FN-A38 Flutter 리포트 화면 자체는 기존 영상 목록으로 동작한다.

### API-06 제외 사유

프런트엔드가 `PATCH /api/auth/me`(프로필 이름 수정)를 호출하지만 서버에 대응 매핑이 없다(코드 검증 완료 사실, `AuthController.java` 전수 확인 결과 `@PatchMapping("/me")` 매핑 자체가 없음). **존재하지 않는 API이므로 본 문서(본문·부록 모두)에서 제외**했다. `03-features.md` 부록A의 FN-A26(프로필 이름 수정, 미구현)이 이 결함을 별도로 추적한다. **에이전트는 이 엔드포인트를 구현/연동 대상으로 취급하지 말 것 — 프런트 `SettingsScreen._editProfile`은 실패한다.**

### ID 검증

- 본문(2~9절)에 배치된 API ID: 01, 02, 03, 07, 08, 11, 14~24, 25~27, 31~38, 43~45, (신규)51 — 31개 + 신규 1개.
- 부록A에 배치된 API ID: 04, 05, 09, 10, 12, 13, 28~30, 39~42, 46~50 — 18개.
- 합계 31 + 18 = 49개 + API-06(의도적 제외) = as-built 기준 50개 전수 반영 + 신규 API-51 = **총 51개 ID(API-01~51) 중 API-06만 결번**. 중복 배치 없음(API-27은 5·8절, API-32는 6·7절에서 의도적으로 재사용 표기 — 동일 ID를 다른 단계에서 참조만 할 뿐 스키마는 한 곳에만 정의).
- MQTT ID: 4절(01, 04) + 10절(02, 03, 05~09) + 12절(10~15) = 2 + 7 + 6 = 15개, MQTT-01~15 전수 반영, 중복 없음.
- 신규 API-51은 기존 max(API-50) 다음 번호로 부여했다.
