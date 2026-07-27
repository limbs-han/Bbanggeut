# API 명세서 (AI/코딩 에이전트용)

> 기준: 5979279 / 2026-07-27 / as-built
> 사람용 원본: [docs/human/04-API명세서.md](../human/04-API명세서.md)

ID 체계: API-01~50(REST) + MQTT-01~15. 사용 상태 기호: `✅ 사용됨` / `🔶 서버구현·클라이언트미사용` / `🔴 클라이언트호출·서버부재`.
JSON 예시는 그대로 복사해 사용 가능 — 주석(`//`)은 타입/필수여부 설명이며 실제 요청 시 제거할 것.

---

## 0. 공통 사항

### 0.1 베이스 URL
- 앱: `https://i15e201.p.ssafy.io` (기본값, `String.fromEnvironment('API_BASE_URL')`, `frontend/lib/core/api_client.dart`)
- 디바이스 에이전트: `device-agent.env`의 `API_BASE_URL` (`ai/device_agent/wj_device_agent/config.py`)

### 0.2 인증 3종

| # | 방식 | 대상 경로 | 헤더/검증 | 실패 응답 | 컨트롤러 경로 |
|---|---|---|---|---|---|
| 1 | 내부 관리자 키 | `/internal/admin/**` | `X-Provisioning-Key` + loopback(127.0.0.1/::1) | 404 `RESOURCE_NOT_FOUND`(위장) | `provisioning/api/ProvisioningController.java` |
| 2 | 기기 credential | `/api/iot/**` | `Authorization: Bearer <keyId>.<secret>` (`/enrollment`만 ROLE_DEVICE_BOOTSTRAP, 나머지 ROLE_DEVICE_OPERATING) | 401 `DEVICE_AUTHENTICATION_FAILED` | `device/api/IotRegistrationController.java`, `iot/auth/DeviceCredentialController.java`, `video/api/IotVideoController.java` |
| 3 | 사용자 JWT | 나머지 전부 | `Authorization: Bearer <JWT>` (HS256, `sub`=userUUID, `sid`=세션UUID) | 401 `AUTHENTICATION_REQUIRED` / 403 `ACCESS_DENIED`·`FORBIDDEN_ROLE` | 그 외 전 컨트롤러 |

`permitAll`: `POST /api/auth/signup`, `POST /api/auth/login`, `POST /api/auth/refresh`, `GET /api/membership-request-links/*/open`, `GET /actuator/health`, `GET /api/live/introspect`.

전역 예외 처리(`common/web/GlobalExceptionHandler.java`) — 모든 엔드포인트 공통(아래 목록은 도메인별 표에서 반복 기재하지 않음):

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
공통 에러 스키마 소스: `common/api/ErrorResponse.java`, `common/api/ApiException.java`.

---

## 1. auth 도메인 (API-01~06)

컨트롤러: `backend/server/src/main/java/com/wj/server/auth/api/AuthController.java` · Base `/api/auth`

#### API-01 `POST /api/auth/signup` ✅
- 인증: 공개
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
- 프런트: `login`/`signUp`→`AuthScreen.submit`(`frontend/lib/ui/auth_screen.dart`)

#### API-02 `POST /api/auth/login` ✅
- 인증: 공개
```json
{ "email": "user@example.com", "password": "string" }
```
- 응답 200: API-01과 동일 스키마(`AuthTokenResponse`)
- 에러: 401 `INVALID_CREDENTIALS`, 429 `LOGIN_RATE_LIMITED`

#### API-03 `POST /api/auth/refresh` ✅ (내부 호출: `api_client.dart._tryRefresh()` 401 인터셉터)
- 인증: 공개
```json
{ "refreshToken": "string" }   // required, @Size 32~2048
```
- 응답 200: `AuthTokenResponse`
- 에러: 401 `INVALID_REFRESH_TOKEN`

#### API-04 `POST /api/auth/logout` ✅
- 인증: 사용자 JWT / 요청 본문 없음 / 응답 204
- 프런트: `SettingsScreen`, `DeviceRegistrationScreen._exitToLogin`

#### API-05 `DELETE /api/auth/me` ✅
- 인증: 사용자 JWT / 요청 없음 / 응답 204
- 에러: 409 `OWNER_MEMBERSHIP_EXISTS`, 404 `RESOURCE_NOT_FOUND`

#### API-06 `PATCH /api/auth/me` 🔴 서버 미구현
- 프런트가 실제로 보내는 요청(서버 스펙 아님, `frontend/lib/core/api_client.dart:152-158`):
```json
{ "displayName": "string" }   // required(추정)
```
- 응답/에러: 없음 — `AuthController.java` 전수 확인 결과 `@PatchMapping("/me")` 매핑 자체가 없음(저장소 grep 0건). 스프링 기본 404 추정(⚠️ 런타임 미확인).
- **주의: 이 엔드포인트를 구현/연동 대상으로 취급하지 말 것 — 프런트 `SettingsScreen._editProfile`은 실패한다.**

---

## 2. device 도메인 (API-07~13)

컨트롤러: `backend/server/src/main/java/com/wj/server/device/api/DeviceController.java` · Base `/api/devices`

#### API-07 `GET /api/devices` ✅
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

#### API-08 `POST /api/devices/claim` ✅
```json
{
  "registrationCode": "string",   // required, @Size 8~12
  "name": "string"                 // optional, @Size 1~80, 공백만 불가
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
- 에러: 429 `CLAIM_RATE_LIMITED`, 409 `DEVICE_CLAIM_REJECTED`

#### API-09 `GET /api/devices/{deviceId}` 🔶 서버구현·클라이언트미사용
- 응답 200: API-08 응답과 동일 스키마(`DeviceResponse`) / 에러: 404 `RESOURCE_NOT_FOUND`
- 참고: `api_client.dart`에 단건조회 메서드 없음 — 죽은 서버 코드, 구현 대상 아님

#### API-10 `PATCH /api/devices/{deviceId}` ✅ (OWNER)
```json
{
  "name": "string",          // optional(있으면 namePresent=true), 공백불가 80자이하
  "retentionDays": 30        // optional(있으면 retentionDaysPresent=true), 1~3650
}
```
- 응답 200: `DeviceResponse`(API-08 스키마)
- 에러: 422 `VALIDATION_FAILED`, 404 `RESOURCE_NOT_FOUND`, 403 `FORBIDDEN_ROLE`

#### API-11 `GET /api/devices/{deviceId}/status` ✅
- 응답 200:
```json
{
  "deviceId": "uuid", "status": "string",
  "recording": false,            // MQTT-05 heartbeat 기반, 기기측 항상 false 스텁
  "uploadQueueDepth": 0,          // 기기측 항상 0 스텁
  "bufferSeconds": null,          // nullable
  "personCount": null,            // nullable
  "checkedAt": "2026-07-27T00:00:00Z"
}
```
- 에러: 404 `RESOURCE_NOT_FOUND`

#### API-12 `POST /api/devices/{deviceId}/transfer-ownership` ✅ (OWNER)
```json
{ "newOwnerMembershipId": "uuid" }   // required
```
- 응답 204 / 에러: 403 `FORBIDDEN_ROLE`, 404, 409 `ALREADY_OWNER`, 409 `TRANSFER_TARGET_NOT_ACTIVE_MEMBER`
- 프런트: `FamilyScreen._MemberTile._transfer`가 `controller.api` **직접 호출**(`AppController.transferOwnership` 래퍼는 미사용)

#### API-13 `DELETE /api/devices/{deviceId}` ✅ (OWNER)
- 응답 204 / 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`

---

## 3. invitation 도메인 (API-14~24)

컨트롤러: `backend/server/src/main/java/com/wj/server/invitation/api/InvitationController.java` · Base `/api`

#### API-14 `POST /api/devices/{deviceId}/invitations` ✅ (OWNER)
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

#### API-15 `POST /api/membership-request-links` ✅
- 요청 없음 / 응답 201:
```json
{ "token": "string", "expiresAt": "2026-07-28T00:00:00Z" }
```

#### API-16 `GET /api/membership-request-links/{token}` ✅
- 응답 200:
```json
{ "email": "string", "displayName": "string", "expiresAt": "2026-07-28T00:00:00Z" }
```
- 에러: 403 `OWNER_MEMBERSHIP_REQUIRED`, 404 `MEMBERSHIP_REQUEST_NOT_FOUND`

#### API-17 `GET /api/membership-request-links/{token}/open` 🔶 서버구현·클라이언트미사용
- 인증: 공개, `token` 정규식 `[A-Za-z0-9_-]{43}`
- 응답: 302 Redirect(`Location: bbanggeut://membership-request/{token}`, 본문 없음) / 에러: 형식불일치 404(본문없음)
- 참고: 앱이 직접 호출하지 않음 — 외부 브라우저/이메일 클라이언트가 열고 앱은 리다이렉트된 딥링크만 수신

#### API-18 `GET /api/devices/{deviceId}/invitations` ✅ (OWNER)
- 응답 200: `List<InvitationResponse>`(API-14 스키마) / 에러: 403, 404

#### API-19 `DELETE /api/devices/{deviceId}/invitations/{invitationId}` ✅ (OWNER)
- 응답 204 / 에러: 403 `FORBIDDEN_ROLE`, 404, 409 `INVITATION_NOT_PENDING`

#### API-20 `GET /api/invitations` ✅
- 응답 200: `List<InvitationResponse>`

#### API-21 `POST /api/invitations/{invitationId}/accept` ✅
- 응답 200:
```json
{
  "id": "uuid", "deviceId": "uuid",
  "user": { "id": "uuid", "email": "string", "displayName": "string" },
  "role": "EDITOR|VIEWER", "status": "ACTIVE|REVOKED", "joinedAt": "2026-07-27T00:00:00Z"
}
```
- 에러: 404, 409 `INVITATION_EXPIRED`, 409 `INVITATION_NOT_PENDING`

#### API-22 `POST /api/invitations/{invitationId}/decline` ✅
- 응답 204 / 에러: 404, 409 `INVITATION_NOT_PENDING`

#### API-23 `GET /api/devices/{deviceId}/members` ✅
- 응답 200: `List<DeviceMemberResponse>`(API-21 스키마) / 에러: 404

#### API-24 `DELETE /api/devices/{deviceId}/members/{membershipId}` ✅ (OWNER)
- 응답 204 / 에러: 403, 404, 409 `OWNER_CANNOT_BE_REVOKED`, 409 `MEMBERSHIP_NOT_ACTIVE`

---

## 4. video 도메인 (API-25~33)

컨트롤러: `video/api/IotVideoController.java`(`/api/iot/videos`, 기기credential), `video/api/VideoController.java`(`/api/videos`, 사용자JWT), `video/api/VideoStatsController.java`(`/api/devices/{deviceId}/stats`)

#### API-25 `POST /api/iot/videos/upload-url` ✅ (기기credential ROLE_DEVICE_OPERATING)
- Header: `Idempotency-Key`(필수, `sourceEventId`와 동일해야 함)
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

#### API-26 `POST /api/iot/videos/complete` ✅ (기기credential)
- Header: `Idempotency-Key`(필수)
```json
{ "videoId": "uuid", "objectETag": "string" }   // objectETag optional, @Size<=200
```
- 응답 200: `VideoResponse`(API-28 스키마) / 에러: 404, 409 `VIDEO_STATE_CONFLICT`, 409 `IDEMPOTENCY_KEY_MISMATCH`, 409 `UPLOAD_INTEGRITY_MISMATCH`, 503

#### API-27 `GET /api/videos` ✅
- Query: `deviceId`(required,uuid), `triggerType?`, `from?`(Instant), `to?`(Instant), `cursor?`, `size?`(기본20, 1~100)
- 응답 200:
```json
{
  "items": [ /* VideoResponse[] — API-28 스키마 */ ],
  "nextCursor": "string", "hasNext": false
}
```
- 에러: 422 `VALIDATION_FAILED`, 404, 422 `INVALID_CURSOR`

#### API-28 `GET /api/videos/{videoId}` ✅
- 응답 200:
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
  "thumbnailUrl": null,
  "createdAt": "2026-07-27T00:00:00Z"
}
```
- ⚠️ `thumbnailUrl`은 코드상 항상 null(썸네일 생성 로직 존재 여부 미확인). 에러: 404

#### API-29 `PATCH /api/videos/{videoId}` ✅ (OWNER/EDITOR)
```json
{
  "title": "string",         // optional(titlePresent)
  "description": "string",   // optional(descriptionPresent)
  "isFavorite": true          // optional(favoritePresent, 내부필드명 favorite)
}
```
- 응답 200: `VideoResponse`(API-28) / 에러: 403 `FORBIDDEN_ROLE`, 404, 422 `VALIDATION_FAILED`

#### API-30 `DELETE /api/videos/{videoId}` ✅ (OWNER)
- 응답 202(비동기 삭제 큐 등록) / 에러: 403 `FORBIDDEN_ROLE`, 404

#### API-31 `POST /api/videos/{videoId}/play-url` ✅
- 응답 200:
```json
{ "url": "https://minio/.../presigned-get", "expiresAt": "2026-07-27T00:05:00Z" }
```
- 에러: 404, 409 `VIDEO_NOT_READY`, 503 `OBJECT_STORAGE_UNAVAILABLE`

#### API-32 `POST /api/videos/{videoId}/download-url` ✅
- 응답 200: API-31과 동일 스키마(`response-content-disposition=attachment` 쿼리 추가된 URL) / 에러: 동일

#### API-33 `GET /api/devices/{deviceId}/stats` ✅
- Query: `from?`(LocalDate), `to?`(LocalDate), `timeZone?`
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

---

## 5. stream·live 도메인 (API-34~38)

컨트롤러: `stream/api/LiveIntrospectionController.java`, `stream/api/StreamController.java`

#### API-34 `GET /api/live/introspect` 🔶 서버구현·클라이언트미사용
- 인증: 공개(토큰 자체 서명 검증) / Query: `token`, `streamId`
- 응답: 204(재생 허용) / 에러: 401(본문없음)
- ⚠️ 호출 주체 미확인(MediaMTX 재생인가 웹훅으로 추정)

#### API-35 `POST /api/devices/{deviceId}/stream-sessions` ✅
- 응답 202:
```json
{
  "sessionId": "uuid", "streamId": "uuid", "deviceId": "uuid",
  "status": "PENDING|READY|FAILED|CLOSED|EXPIRED",
  "playUrl": null,                     // READY일 때만 값 존재, HLS URL
  "heartbeatIntervalSeconds": 15,
  "viewerExpiresAt": "2026-07-27T00:00:45Z",
  "edgeHardExpiresAt": "2026-07-27T00:02:00Z",
  "failureCode": null,
  "createdAt": "2026-07-27T00:00:00Z"
}
```
- 에러: 404, 409 `DEVICE_OFFLINE`
- 실사용: `EmbeddedLivePlayer._start`(`HomeScreen`); `LiveScreen._start`는 미사용 화면

#### API-36 `GET /api/stream-sessions/{sessionId}` ✅
- 응답 200: API-35와 동일 스키마 / 에러: 404 (2초 간격 폴링용)

#### API-37 `DELETE /api/stream-sessions/{sessionId}` ✅
- 응답 204 / 에러: 404

#### API-38 `POST /api/stream-sessions/{sessionId}/heartbeat` ✅
- 응답 204 / 에러: 404

---

## 6. subscription 도메인 (API-39~41)

컨트롤러: `subscription/api/SubscriptionController.java` · Base `/api/devices/{deviceId}/subscription`

#### API-39 `GET /api/devices/{deviceId}/subscription` ✅
- 응답 200:
```json
{ "deviceId": "uuid", "active": true, "graceUntil": null, "premiumRetentionDays": 365 }
```
- 에러: 404

#### API-40 `PUT /api/devices/{deviceId}/subscription` ✅ (OWNER)
- 요청 본문 없음 / 응답 200: API-39 스키마 / 에러: 403, 404

#### API-41 `DELETE /api/devices/{deviceId}/subscription` ✅ (OWNER)
- 응답 200: API-39 스키마 / 에러: 403, 404, 409 `SUBSCRIPTION_NOT_ACTIVE`

---

## 7. home 도메인 (API-42)

컨트롤러: `home/api/HomeSummaryController.java`

#### API-42 `GET /api/devices/{deviceId}/home-summary` ✅
- Query: `timeZone?`
- 응답 200:
```json
{
  "deviceId": "uuid", "date": "2026-07-27", "timeZone": "Asia/Seoul",
  "captureCount": 5, "savedCount": 3, "memoCount": 1,
  "latestHighlight": null   // nullable, VideoResponse(API-28) 스키마
}
```
- 에러: 404, 422 `VALIDATION_FAILED`

---

## 8. iot 도메인 (API-43~46)

#### API-43 `POST /api/iot/registration-codes` ✅ (기기credential ROLE_DEVICE_OPERATING)
- 컨트롤러: `device/api/IotRegistrationController.java` / 요청 본문 없음(`DevicePrincipal`만 사용)
- 응답 200:
```json
{ "registrationCode": "string", "expiresAt": "2026-07-27T00:02:00Z" }
```
- 에러: 409 `DEVICE_ALREADY_CLAIMED`
- 호출부: `ai/device_agent/wj_device_agent/provision.py`(`registration-code` 서브커맨드)

#### API-44 `POST /api/iot/enrollment` ✅ (기기credential ROLE_DEVICE_BOOTSTRAP)
- 컨트롤러: `iot/auth/DeviceCredentialController.java` / 요청 본문 없음
- 응답 200:
```json
{
  "deviceId": "uuid", "serialNumber": "string", "keyId": "string",
  "bearerToken": "{keyId}.{secret}", "purpose": "BOOTSTRAP|OPERATING",
  "expiresAt": "2026-08-26T00:00:00Z", "mqttUsername": null
}
```
- 에러: 404, 401 `DEVICE_CREDENTIAL_STALE`, 403 `DEVICE_CREDENTIAL_PURPOSE_INVALID`
- 호출부: `DeviceApi.enroll`(`ai/device_agent/wj_device_agent/provision.py`)

#### API-45 `POST /api/iot/credentials/rotate` ✅ (기기credential ROLE_DEVICE_OPERATING)
- 요청 본문 없음 / 응답 200: API-44와 동일 스키마 / 에러: 동일
- 호출부: `DeviceApi.rotate`(`provision.py`)

#### API-46 `GET /api/devices/{deviceId}/event-stats` 🔶 서버구현·클라이언트미사용
- 컨트롤러: `iot/event/EventStatsController.java` / Query: `from?`,`to?`(LocalDate ISO),`timeZone?`
- 응답 200:
```json
{
  "deviceId": "uuid", "from": "2026-07-01", "to": "2026-07-27", "timeZone": "Asia/Seoul",
  "detectedCount": 10, "uploadedVideoCount": 8,
  "byType": [ { "name": "LAUGHTER", "count": 8 } ],
  "dailyCounts": [ { "date": "2026-07-27", "count": 2 } ]
}
```
- 에러: 404, 422 `VALIDATION_FAILED`(from>to 또는 366일 초과)
- **주의: 서버는 정교히 구현되어 있으나 프런트(`LaughReportScreen`)는 대신 API-33을 사용 — 신규 연동 시 이 API를 "이미 쓰이는 것"으로 가정하지 말 것.**

---

## 9. provisioning 도메인 (API-47~49)

컨트롤러: `provisioning/api/ProvisioningController.java` · Base `/internal/admin/devices` · 내부 관리자 키 전용

#### API-47 `POST /internal/admin/devices` 🔶
```json
{
  "serialNumber": "string",     // required, @Size<=80
  "name": "string",              // required, @Size<=80
  "model": "string",              // required, @Size<=80
  "firmwareVersion": "string"     // optional, @Size<=40
}
```
- 응답 201: API-44와 동일 스키마(`ProvisionedDeviceResponse`) / 에러: 409 `DEVICE_SERIAL_ALREADY_ACTIVE`

#### API-48 `POST /internal/admin/devices/{deviceId}/credentials/rotate` 🔶
- 응답 200: `ProvisionedDeviceResponse` / 에러: 404, 409 `DEVICE_REVOKED`

#### API-49 `DELETE /internal/admin/devices/{deviceId}/credentials` 🔶
- 응답 204 / 에러: 404
- 참고: 47~49 전부 코드상 호출부 없음(운영자가 curl 등으로 직접 호출하는 절차로 추정). 인증실패(키불일치/비-loopback) 시 404로 위장.

---

## 10. audit 도메인 (API-50)

컨트롤러: `audit/api/AccessLogController.java`

#### API-50 `GET /api/devices/{deviceId}/access-logs` ✅ (OWNER)
- Query: `cursor?`, `size?`(기본20, 1~100)
- 응답 200:
```json
{
  "items": [
    {
      "id": 1, "deviceId": "uuid", "actorUserId": "uuid", "actorDeviceId": null,
      "action": "MEMBER_INVITE",
      "targetType": "string", "targetId": "uuid",
      "outcome": "SUCCESS|DENIED|FAILED", "reasonCode": null,
      "createdAt": "2026-07-27T00:00:00Z"
    }
  ],
  "nextCursor": "string", "hasNext": false
}
```
- `action` enum 값: `MEMBER_INVITE, MEMBER_REVOKE, DEVICE_CLAIM, DEVICE_UPDATE, DEVICE_REVOKE, VIDEO_LIST, VIDEO_VIEW, VIDEO_PLAY, VIDEO_DOWNLOAD, VIDEO_EDIT, VIDEO_DELETE, VIDEO_UPDATE, STREAM_OPEN, STREAM_HEARTBEAT, STREAM_CLOSE`
- 에러: 422 `VALIDATION_FAILED`, 403 `FORBIDDEN_ROLE`, 404, 422 `INVALID_CURSOR`

---

## 11. MQTT 토픽 (MQTT-01~15)

토픽 베이스: `${app.mqtt.environment}/wj/v2`(예: `prod/wj/v2`). 브로커: Mosquitto + `dynamic-security`.

> v2 마이그레이션(커밋 `692453b`): `wj/v1`→`wj/v2`, `schemaVersion` `1.0`→`2.0`. 백엔드는 `2.0`이 아닌 payload를 조용히 폐기한다. 기존 기기 ACL은 백엔드 시작 시 `iot/mqtt/MqttTopicAclMigrationWorker.java`가 v2로 자동 이관.

### 11.1 `wj/v2` 네임스페이스 (기기 실운영, 9개)

#### MQTT-01 `{base}/devices/{deviceId}/commands` — 발행(백엔드→기기), QoS1 ✅
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
- 발행: `backend/.../stream/application/StreamCommandPublisher.java`, `stream/application/StreamService.java`, `iot/mqtt/PahoMqttGateway.java`
- 구독: `ai/device_agent/wj_device_agent/agent.py:103` (기기측 `PING` 처리분기는 백엔드가 발행 안 함 — 죽은 코드)

#### MQTT-02 `{base}/devices/+/status` — 구독(기기→백엔드), QoS1 ⚠️
```json
{
  "schemaVersion": "2.0", "deviceId": "uuid", "state": "ONLINE",
  "reason": "BOOT_COMPLETED",
  "firmwareVersion": "string", "occurredAt": "2026-07-27T00:00:00Z"
}
```
- `state`: `ONLINE|OFFLINE`, `reason`: `BOOT_COMPLETED|CONNECTION_LOST|SERVICE_STOPPED`
- 백엔드는 `state`/`firmwareVersion`만 읽음 — `reason`/`occurredAt`은 파싱하지 않고 버려짐(에러 아님)
- ⚠️ retain=true(기기측)에 대한 백엔드 처리 방식은 미확인(코드상 확인 불가)
- 발행: `ai/device_agent/wj_device_agent/agent.py:71-76(will_set),92,104` / 구독: `backend/.../iot/telemetry/MqttInboundHandler.java:105-111`

#### MQTT-03 `{base}/devices/+/commands/ack` — 구독(기기→백엔드), QoS1 ⚠️
```json
{
  "schemaVersion": "2.0", "requestId": "uuid", "deviceId": "uuid",
  "status": "ACCEPTED",
  "errorCode": null, "message": null, "occurredAt": "2026-07-27T00:00:00Z",
  "streamId": "uuid", "sessionId": "uuid"
}
```
- `status`: `ACCEPTED|SUCCEEDED|FAILED|REJECTED|EXPIRED`
- 백엔드는 `requestId`/`status`만 로그로 남김 — `errorCode`/`message`/`occurredAt`/`streamId`/`sessionId`는 미사용
- 발행: `agent.py:133,237-262` / 구독: `backend/.../iot/telemetry/MqttInboundHandler.java`(commandAck())

#### MQTT-04 `{base}/devices/+/stream/events` — 구독(기기→백엔드), QoS1 ⚠️
```json
{
  "schemaVersion": "2.0", "eventId": "uuid", "requestId": "uuid", "deviceId": "uuid",
  "streamId": "uuid", "type": "STREAM_STARTING",
  "occurredAt": "2026-07-27T00:00:00Z", "hardExpiresAt": "2026-07-27T00:02:00Z",
  "errorCode": null, "sessionId": "uuid"
}
```
- `type`: `STREAM_STARTING|STREAM_READY|STREAM_ERROR|STREAM_HARD_EXPIRED|STREAM_STOPPED`
- 백엔드 `streamEvent()` switch문은 `STREAM_STARTING`을 `default -> {}`로 조용히 무시(상태공백, 장애아님). `eventId/requestId/occurredAt/sessionId`도 미사용
- 발행: `agent.py:264-285` / 구독: `backend/.../iot/telemetry/MqttInboundHandler.java`(streamEvent()), `stream/application/StreamEventService.java`

#### MQTT-05 `{base}/devices/+/heartbeat` — 구독(기기→백엔드), QoS0 ⚠️
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
- 30초 주기. `recording`/`uploadQueueDepth`는 필드명은 일치하나 항상 스텁값 — `DeviceStatusResponse`(API-11)에 실제 상태 미반영. `sentAt/uptimeSeconds/clockUnsynced/nodes/streaming`은 백엔드가 읽지 않는 잉여 필드
- 발행: `agent.py:211-225` / 구독: `backend/.../iot/telemetry/MqttInboundHandler.java`(heartbeat())

#### MQTT-06 `{base}/devices/+/registration` — 구독(설계상, 실제 발행자 없음), QoS1 🔶
```json
{ "schemaVersion": "2.0", "deviceId": "uuid", "mode": "ENABLED", "expiresAt": "2026-07-27T00:05:00Z" }
```
- `mode`: `ENABLED|DISABLED`(ENABLED는 만료 5분 이내일 때만 반영)
- 백엔드 핸들러는 존재하나 기기 발행 코드 없음 — 등록코드 발급은 API-43(HTTP)로만 동작
- 구독만: `backend/.../iot/telemetry/MqttInboundHandler.java:90-103` / 발행: 없음

#### MQTT-07 `{base}/devices/+/events` — 구독(설계상, 실제 발행자 없음), QoS1 🔶
```json
{
  "schemaVersion": "2.0", "deviceId": "uuid", "eventId": "uuid",
  "type": "LAUGHTER",
  "occurredAt": "2026-07-27T00:00:00Z",
  "confidence": 0.9,   // 0~1, LAUGHTER/WAKE_WORD는 필수, TOUCH/MANUAL은 금지
  "localClip": { "state": "SEGMENTS_LOCKED", "beforeMs": 60000, "afterMs": 60000, "mergeWindowMs": 30000 },
  "source": { "nodeId": "string", "component": "YAMNET", "modelVersion": "string" }
}
```
- `type`: `LAUGHTER|WAKE_WORD|TOUCH|MANUAL`, `localClip.state`: `SEGMENTS_LOCKED|GENERATING|QUEUED|FAILED`, `source.component`: `YAMNET|KEYWORD_SPOTTING|TOUCH_SENSOR|APP|LOCAL_CONTROL`
- 웃음감지→업로드는 이 토픽 없이 API-25/26(HTTP)만으로 동작, `device_events` 테이블(V18) 사실상 미사용
- 구독만: `backend/.../iot/telemetry/MqttInboundHandler.java`(detectionEvent()), `iot/event/DeviceEventService.java` / 발행: 없음

#### MQTT-08 `$CONTROL/dynamic-security/v1` — 발행(백엔드→브로커), QoS1 (해당없음: 브로커 관리 채널)
```json
{ "commands": [ { "command": "createClient", "...": "..." } ] }
```
- `command`: `createClient|createRole|addRoleACL|addClientRole|modifyClient|enableClient|getClient|disableClient|deleteClient|deleteRole`
- 소스: `backend/.../iot/mqtt/PahoMqttGateway.java`

#### MQTT-09 `$CONTROL/dynamic-security/v1/response` — 구독(브로커→백엔드), QoS1 (해당없음)
- 페이로드: dynsec 커맨드 응답(JSON, 스키마 비공개) / 소스: `backend/.../iot/mqtt/PahoMqttGateway.java`

### 11.2 `homecam/v2` 네임스페이스 (실험 단계, 운영 비활성, 6개)

> 운영 배포 스크립트(`ai/yolo/run_edge_ai_mvp.sh`, `run_edge_ai_recording.sh`)가 `MQTT_HOST=`(빈값)로 넘겨 아래 6개 토픽 전부 코드 경로 자체가 비활성. `ai/yolo/run_ai_stack.sh`(로컬 수동검증)에서만 동작. **에이전트는 이 6개를 운영 중인 파이프라인으로 가정하지 말 것.**

#### MQTT-10 `homecam/v2/{device_id}/ai/vision/state` — 발행(YOLO), QoS0 🔴
```json
{
  "schema_version": "string", "device_id": "string", "sequence": 1,
  "state": "TRACKING", "direction": "LEFT",
  "target_ids": [1], "target_count": 1, "total_stable_objects": 1,
  "center_x": 0.5, "center_y": 0.5, "error_x": 0.1, "error_y": -0.1,
  "group_box": [0,0,1,1], "limited_group": false, "frame_index": 100,
  "sent_at": "2026-07-27T00:00:00Z", "ttl_ms": 500, "created_at": "2026-07-27T00:00:00Z",
  "monotonic_ns": 0, "object_counts": {"person":1}, "track_ids": [1]
}
```
- `state`: `TRACKING|NO_TARGET_HOLD|RETURN_HOME`, `direction`: `LEFT|RIGHT|UP|DOWN|HOLD|HOME` 조합
- 발행: `ai/yolo/vision_mqtt_publisher.py:31`, `ai/yolo/yolov8_autoframe_jetson.py:82-97` / 내부구독(백엔드 아님): `ai/yolo/event_fusion_service.py` / 백엔드 구독: 없음

#### MQTT-11 `homecam/v2/{device_id}/control/framing/target` — 발행(YOLO), QoS0 🔴
- 페이로드: MQTT-10과 동일 재발행
- 발행: `ai/yolo/vision_mqtt_publisher.py:126-131` / **구독자 전무**(서보 제어기 `servo_controller` 미구현, FN-H03)

#### MQTT-12 `homecam/v2/{device_id}/ai/vision/status` — 발행(YOLO, LWT), QoS1(retain) 🔴
```json
{ "device_id": "string", "component": "yolo", "status": "online" }
```
- 발행: `ai/yolo/vision_mqtt_publisher.py:35,47-54,92-99` / 백엔드 구독: 없음

#### MQTT-13 `homecam/v2/{device_id}/ai/laughter/detected` — 발행(YAMNet), QoS1 🔴
```json
{
  "schema_version": "string", "event_id": "uuid", "device_id": "string",
  "event_type": "laughter", "detected_at": "2026-07-27T00:00:00Z", "monotonic_ns": 0,
  "score": 0.9, "class_name": "Laughter",
  "clip": { "pre_seconds": 60, "post_seconds": 60 },
  "model": { "name": "YAMNet", "threshold": 0.25, "consecutive": 2 }
}
```
- 발행: `ai/yamnet/mqtt_event_publisher.py:36,113-154` / 내부구독(백엔드 아님): `ai/yolo/event_fusion_service.py` / 백엔드 구독: 없음

#### MQTT-14 `homecam/v2/{device_id}/ai/status` — 발행(YAMNet, LWT), QoS1(retain) 🔴
```json
{ "device_id": "string", "component": "yamnet", "status": "online" }
```
- 발행: `ai/yamnet/mqtt_event_publisher.py:38` / 백엔드 구독: 없음

#### MQTT-15 `homecam/v2/{device_id}/events/memory-candidate` — 발행(event_fusion), QoS1 🔴
```json
{
  "schema_version": "1.1", "fused_at": "2026-07-27T00:00:00Z", "source_schema_version": "string",
  "vision_context": {
    "available": true, "age_ms": 500, "object_count": 1, "track_ids": [1],
    "person_count": 1, "cat_count": 0, "dog_count": 0,
    "target_ids": [1], "target_count": 1, "total_stable_objects": 1,
    "camera_state": "TRACKING", "camera_direction": "HOLD",
    "error_x": 0.1, "error_y": -0.1, "limited_group": false
  }
}
```
- 원본 laughter 이벤트(MQTT-13) 필드 + 위 `vision_context`(vision_state 나이 `--max-vision-age-ms` 기본 2000ms 이내면 부착)
- 발행: `ai/yolo/event_fusion_service.py:67-120,170-243` / 백엔드 구독: 없음

기기별 MQTT 계정 ACL(`PahoMqttGateway.create`): 발행 허용 `status,heartbeat,registration,events,stream/events,commands/ack` / 구독 허용 `commands`만. `homecam/v2`은 이 ACL 체계 밖.

---

## 12. 미디어 경로 요약

| 구간 | 프로토콜/형식 | 핵심 설정 | 소스 |
|---|---|---|---|
| Jetson→MediaMTX | RTSPS, `rtsps://{user}:{pass}@{host}:{port}/live/{stream_id}`(기본 host `i15e201.p.ssafy.io`, port `8322`) — `config.py`가 자격증명+`/live/{stream_id}` 경로+`MEDIA_TLS_CA_CERT` 필수 강제 | H.264(`libx264 ultrafast zerolatency`)+AAC/무음(`-an`) | `ai/device_agent/wj_device_agent/stream.py`, `configure_media.py`, `config.py` |
| MediaMTX→앱 | HLS, `{media-base-url}/{streamId}/index.m3u8?token={liveToken}`(기본 `http://localhost:8888/live`) | 토큰TTL 30초, 20초 재조회 | `backend/.../config/StreamProperties`, `frontend/lib/ui/live_screen.dart` |
| 기기→MinIO | HTTPS PUT(presigned) | 업로드URL TTL 15분, `x-amz-meta-sha256` 헤더 | `backend/.../storage/ObjectStorageService.java` |
| 앱→MinIO(재생/다운로드) | HTTPS GET(presigned, Spring 경유 발급) | 읽기URL TTL 5분, 다운로드는 `response-content-disposition=attachment` | 上同 |

MinIO 설정(`app.storage.*`): `endpoint`(기본 `http://localhost:9000`), `bucket`(기본 `wj-videos`), `access-key`/`secret-key`(기본 `minioadmin`/`minioadmin`, 운영에서는 환경변수 필수).

⚠️ 앱은 `playUrl`을 서버가 내려주는 값 그대로 사용할 뿐 직접 조립하지 않는다 — 실제 URL 포맷(m3u8 여부 등)이 위 표와 정확히 일치하는지는 프런트 코드만으로는 확정 불가(미확인, 백엔드 `StreamProperties` 설정 기준으로만 위 포맷을 기재함).

---

## 13. 검증

- REST: 사람용 원본 API-01~50과 **정확히 50개** 일치(✅42 / 🔶7[API-09,17,34,46,47,48,49] / 🔴1[API-06]).
- MQTT: 사람용 원본 MQTT-01~15와 **정확히 15개** 일치(`wj/v2` 9개[✅1/⚠️4/🔶2/해당없음2] + `homecam/v2` 6개[전부 🔴]).
- 도메인별 개수: auth6 + device7 + invitation11 + video9 + stream·live5 + subscription3 + home1 + iot4 + provisioning3 + audit1 = 50.

## 14. MVP 시연 경로 API (2026-07-27 확정)

①API-01,02 · ②API-08,43 · ③API-35~38+MQTT-01/04 · ④API-25,26,27,31 · ⑤서버 API 불요(로컬 편집) · ⑥API-32 · ⑦API-27,33 (+REQ-F-42 신규 리포트용 API 미정·개발 예정) · 전제: API-07,11. 그 외 전부 MVP 외(확장).
