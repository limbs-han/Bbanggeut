# API 명세서

> 기준: 5979279 / 2026-07-27 / 구현 코드 기준(as-built)

본 문서는 다음 4개 인벤토리 산출물을 근거로 작성되었으며, 추측 없이 코드에서 직접 확인된 사실만 기재한다. 확인 불가 항목은 `⚠️ 미확인`으로 표시한다.

- `docs/superpowers/plans/2026-07-27-inventory/backend.md` — REST 49개 엔드포인트, DTO, MQTT(백엔드), DB, 설정
- `docs/superpowers/plans/2026-07-27-inventory/frontend.md` — 프런트엔드 호출처(`api_client.dart` 42개 메서드)
- `docs/superpowers/plans/2026-07-27-inventory/ai-edge.md` — 엣지(디바이스 에이전트/AI 파이프라인) MQTT·미디어 송출
- `docs/superpowers/plans/2026-07-27-inventory/cross-check.md` — 사용 상태 판정(REST 50행: ✅42/🔶7/🔴1, MQTT 15행)

각 엔드포인트/토픽의 **사용 상태**는 반드시 `cross-check.md`의 판정을 그대로 따른다.

---

## 1. 공통 사항

### 1.1 베이스 URL

- 프런트엔드 기본값: `https://i15e201.p.ssafy.io` (`String.fromEnvironment('API_BASE_URL', defaultValue: ...)`, `frontend/lib/core/api_client.dart`)
- 디바이스 에이전트가 호출하는 API 베이스 URL은 `device-agent.env`의 `API_BASE_URL`로 주입(`ai/device_agent/wj_device_agent/config.py`).

### 1.2 인증 3종 (`backend/server/src/main/java/com/wj/server/config/SecurityConfig.java`, `SecurityFilterChain` Order 1~3)

| # | 방식 | 대상 경로(matcher) | 검증 방법 | 실패 응답 | 대상 컨트롤러 |
|---|---|---|---|---|---|
| 1 | 내부 관리자 키 | `/internal/admin/**` | `ProvisioningAuthenticationFilter` — 헤더 `X-Provisioning-Key` + loopback(127.0.0.1/::1) 검사 | `app.provisioning.enabled=false`거나 키 불일치/비-loopback이면 **404 RESOURCE_NOT_FOUND**로 위장(엔드포인트 존재 자체를 숨김) | `ProvisioningController` |
| 2 | 기기 credential(Bearer) | `/api/iot/**` | `DeviceAuthenticationFilter`+`DeviceCredentialAuthenticator` — `Authorization: Bearer <keyId>.<secret>`. `/api/iot/enrollment`는 `ROLE_DEVICE_BOOTSTRAP`, 나머지는 `ROLE_DEVICE_OPERATING` | **401 DEVICE_AUTHENTICATION_FAILED** | `IotRegistrationController`, `DeviceCredentialController`, `IotVideoController` |
| 3 | 사용자 JWT | 나머지 전부 | OAuth2 Resource Server + HS256 JWT(`config/JwtConfig.java`). `sub`=사용자 UUID, `sid`=세션 UUID | 미인증 **401 AUTHENTICATION_REQUIRED**, 인가 실패 **403 ACCESS_DENIED**(Spring Security 레벨) 또는 컨트롤러/서비스 레벨 `403 FORBIDDEN_ROLE` 등 | 그 외 전 컨트롤러 |

`permitAll`(인증 불필요): `POST /api/auth/signup`, `POST /api/auth/login`, `POST /api/auth/refresh`, `GET /api/membership-request-links/*/open`, `GET /actuator/health`, `GET /api/live/introspect`.

### 1.3 공통 에러 형식

`common/api/ErrorResponse`(`code`, `message`, `requestId`, `fieldErrors`) — `fieldErrors`는 `@JsonInclude(NON_NULL)`이라 null이면 응답 본문에서 생략된다.

`GlobalExceptionHandler`(`@RestControllerAdvice`)가 처리하는 전역 예외(아래 4개는 모든 엔드포인트에 잠재적으로 적용되므로 2절 각 항목 표에는 반복 표기하지 않고, 엔드포인트별 비즈니스 에러 코드만 기재한다):

| 예외 | 상태코드 | 코드 |
|---|---|---|
| `ApiException` | `exception.status()` | `exception.code()`(비즈니스 에러, 아래 2절에 개별 기재) |
| `MethodArgumentNotValidException`(Bean Validation 실패) | 422 | `VALIDATION_FAILED` |
| `HttpMessageNotReadableException`(JSON 파싱 실패) | 422 | `MALFORMED_JSON` |
| `MissingRequestHeaderException` | 422 | `MISSING_REQUIRED_HEADER` |
| 그 외 `Exception` | 500 | `INTERNAL_SERVER_ERROR` |

출처: `common/web/GlobalExceptionHandler.java`, `common/api/ApiException.java`, `common/api/ErrorResponse.java`.

---

### 1.4 MVP 시연 경로 관련 API (2026-07-27 확정)

시연 MVP 7항목(`01-서비스기획.md` 8절)이 실제로 사용하는 API/MQTT는 다음과 같다. 여기 없는 항목은 MVP 외(확장).

- ① 가입/로그인: API-01, API-02 · ② 기기 등록: API-08(claim), API-43(기기측 코드 발급) · ③ 라이브: API-35~38 + MQTT-01/04 · ④ 이벤트 영상: API-25/26(기기 업로드), API-27(목록), API-31(재생) · ⑤ 편집: 서버 API 불요(로컬 편집 기준) · ⑥ 다운로드: API-32(원본), 편집본은 기기 저장 · ⑦ 통계: API-27(`from`/`to` 캘린더 집계), API-33(웃음 통계); 신규 리포트 화면(REQ-F-42)용 API는 미정(개발 예정)
- (전제) 기기 목록/상태: API-07, API-11

## 2. REST API

REST 항목 수 = backend 인벤토리 49개(메서드 레벨 매핑, 15개 컨트롤러 전수) + 🔴 1개(`PATCH /api/auth/me`, 프런트가 호출하지만 서버 미구현) = **50개**. API-01부터 도메인 순서(auth → device → invitation → video → stream/live → subscription → home → iot → provisioning → audit)로 순번을 부여했다.

사용 상태 기호(`cross-check.md` 기준): `✅ 사용됨` / `🔶 서버 구현·클라이언트 미사용` / `🔴 클라이언트 호출·서버 부재`.

### 2.1 auth 도메인 (API-01 ~ API-06)

기준 컨트롤러: `auth/api/AuthController.java`, Base path `/api/auth`

#### API-01 `POST /api/auth/signup`
- 인증: 공개(permitAll)
- 요청

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| email | String | 필수 | `@NotBlank @Email @Size≤320` |
| password | String | 필수 | `@NotBlank @Size 10~72` |
| displayName | String | 필수 | `@NotBlank @Size≤60` |
| (Header) X-Client-Name | String | 옵션 | 클라이언트 식별자(세션 표시용) |

- 응답: `201 AuthTokenResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| accessToken | String | 필수 | 액세스 토큰 |
| refreshToken | String | 필수 | 리프레시 토큰 |
| tokenType | String | 필수 | `"Bearer"` 고정 |
| expiresIn | long | 필수 | 초 단위 만료시간 |
| user.id | UUID | 필수 | 사용자 ID |
| user.email | String | 필수 | 이메일 |
| user.displayName | String | 필수 | 표시 이름 |

- 에러: 409 `EMAIL_ALREADY_EXISTS`
- 사용 상태: ✅ 사용됨 — frontend `signUp`(#4) → `AuthScreen.submit`
- 소스: `backend/server/src/main/java/com/wj/server/auth/api/AuthController.java`, `auth/application/AuthService.java`, `auth/api/SignUpRequest`, `auth/api/AuthTokenResponse`, `auth/api/UserSummary`

#### API-02 `POST /api/auth/login`
- 인증: 공개(permitAll)
- 요청

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| email | String | 필수 | `@NotBlank @Email @Size≤320` |
| password | String | 필수 | `@NotBlank @Size≤72` |
| (Header) X-Client-Name | String | 옵션 | 클라이언트 식별자 |

- 응답: `200 AuthTokenResponse` (API-01과 동일 스키마)
- 에러: 401 `INVALID_CREDENTIALS`, 429 `LOGIN_RATE_LIMITED`
- 사용 상태: ✅ 사용됨 — frontend `login`(#3) → `AuthScreen.submit`
- 소스: `auth/api/AuthController.java`, `auth/application/AuthService.java`, `auth/application/LoginAttemptService.java`

#### API-03 `POST /api/auth/refresh`
- 인증: 공개(permitAll)
- 요청

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| refreshToken | String | 필수 | `@NotBlank @Size 32~2048` |
| (Header) X-Client-Name | String | 옵션 | 클라이언트 식별자 |

- 응답: `200 AuthTokenResponse`
- 에러: 401 `INVALID_REFRESH_TOKEN`
- 사용 상태: ✅ 사용됨 — 공개 42개 메서드 목록에는 없으나 `api_client.dart`의 private `_tryRefresh()`(401 인터셉터)가 실제 호출
- 소스: `auth/api/AuthController.java`, `auth/application/AuthService.java`

#### API-04 `POST /api/auth/logout`
- 인증: 사용자 JWT (jwt.sub, jwt.sid 사용, body 없음)
- 요청: 없음
- 응답: `204 No Content`
- 에러: (401 `AUTHENTICATION_REQUIRED` — 필터 레벨)
- 사용 상태: ✅ 사용됨 — frontend `logout`(#5) → `SettingsScreen`, `DeviceRegistrationScreen._exitToLogin`
- 소스: `auth/api/AuthController.java`, `auth/application/AuthService.java`

#### API-05 `DELETE /api/auth/me`
- 인증: 사용자 JWT
- 요청: 없음
- 응답: `204 No Content`
- 에러: 409 `OWNER_MEMBERSHIP_EXISTS`(소유 기기 있음), 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `withdraw`(#7) → `SettingsScreen._withdraw`
- 소스: `auth/api/AuthController.java`, `auth/application/AuthService.java`

#### API-06 🔴 `PATCH /api/auth/me` — **서버 미구현**
- 인증: (프런트 기준) 사용자 JWT
- 요청(프런트가 실제로 보내는 바디, 서버 스펙 아님)

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| displayName | String | 필수(추정) | 프런트 `updateProfile` 호출 바디 |

- 응답: 없음(서버에 핸들러가 없어 실패 예상)
- 에러: 없음(매핑 자체가 없어 스프링 기본 404 응답이 될 것으로 추정, ⚠️ 실제 발생 응답 코드는 런타임 미확인)
- 사용 상태: 🔴 클라이언트 호출·서버 부재 — frontend `updateProfile`(#6, `api_client.dart:152-158`)가 `PATCH /api/auth/me`를 호출하지만, `AuthController.java`(1~72행 전체 확인) 및 저장소 전체 grep 결과 `@PatchMapping("/me")`가 전혀 없다. `SettingsScreen._editProfile`(프로필 수정) 사용 시 실패할 것으로 판단됨.
- 소스: (프런트) `frontend/lib/core/api_client.dart:152-158`, `frontend/lib/ui/settings_screen.dart`(`_editProfile`) / (백엔드) 대응 코드 없음 — `backend/server/src/main/java/com/wj/server/auth/api/AuthController.java` 전수 확인, 매핑 없음

### 2.2 device 도메인 (API-07 ~ API-13)

기준 컨트롤러: `device/api/DeviceController.java`, Base path `/api/devices`

#### API-07 `GET /api/devices`
- 인증: 사용자 JWT
- 요청: 없음
- 응답: `200 List<DeviceSummaryResponse>`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| id | UUID | 필수 | 기기 ID |
| name | String | 필수 | 기기 이름 |
| model | String | 필수 | 모델명 |
| status | String | 필수 | UNCLAIMED/ONLINE/OFFLINE/REVOKED |
| myRole | String | 필수 | 호출자의 역할 |
| retentionDays | int | 필수 | 보관 기간(일) |
| lastSeenAt | Instant | 필수 | 마지막 접속 시각 |

- 에러: 없음
- 사용 상태: ✅ 사용됨 — frontend `listDevices`(#9) → `AppController.refreshDevices`
- 소스: `device/api/DeviceController.java`, `device/application/DeviceService.java`, `device/api/DeviceSummaryResponse`

#### API-08 `POST /api/devices/claim`
- 인증: 사용자 JWT
- 요청

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| registrationCode | String | 필수 | `@NotBlank @Size 8~12` |
| name | String | 옵션 | `@Size 1~80`, 공백만 불가 |

- 응답: `201 DeviceResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| id | UUID | 필수 | 기기 ID |
| name | String | 필수 | 기기 이름 |
| model | String | 필수 | 모델명 |
| status | String | 필수 | 상태 |
| myRole | String | 필수 | 호출자 역할 |
| retentionDays | int | 필수 | 보관 기간(일) |
| lastSeenAt | Instant | 필수 | 마지막 접속 시각 |
| serialNumber | String | 필수 | 시리얼번호 |
| firmwareVersion | String | 필수 | 펌웨어 버전 |
| claimedAt | Instant | 필수 | 등록(claim) 시각 |

- 에러: 429 `CLAIM_RATE_LIMITED`, 409 `DEVICE_CLAIM_REJECTED`
- 사용 상태: ✅ 사용됨 — frontend `claimDevice`(#10) → `DeviceRegistrationScreen._register`
- 소스: `device/api/DeviceController.java`, `device/application/ClaimAttemptService.java`, `device/api/DeviceResponse`

#### API-09 `GET /api/devices/{deviceId}`
- 인증: 사용자 JWT
- 요청: PathVariable `deviceId`(UUID, 필수)
- 응답: `200 DeviceResponse` (API-08 응답과 동일 스키마)
- 에러: 404 `RESOURCE_NOT_FOUND`
- 사용 상태: 🔶 서버 구현·클라이언트 미사용 — `api_client.dart`에 단건 조회 메서드 없음(같은 경로에 대해 patch/delete만 존재), ai-edge도 미호출
- 소스: `device/api/DeviceController.java`, `device/application/DeviceService.java`

#### API-10 `PATCH /api/devices/{deviceId}`
- 인증: 사용자 JWT(OWNER)
- 요청: `UpdateDeviceRequest`(class, partial update — `@JsonSetter`+`*Present` 플래그)

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| name | String | 옵션(있으면 namePresent=true) | 공백 불가, 80자 이하 |
| retentionDays | Integer | 옵션(있으면 retentionDaysPresent=true) | 1~3650 범위 |

- 응답: `200 DeviceResponse`
- 에러: 422 `VALIDATION_FAILED`(필드 0개 / name 공백·80자 초과 / retentionDays 범위 밖), 404 `RESOURCE_NOT_FOUND`, 403 `FORBIDDEN_ROLE`(OWNER 아님)
- 사용 상태: ✅ 사용됨 — frontend `updateDevice`(#21, `{name?, retentionDays?}`) → `SettingsScreen._editDevice`/`_editRetention`
- 소스: `device/api/DeviceController.java`, `device/api/UpdateDeviceRequest`

#### API-11 `GET /api/devices/{deviceId}/status`
- 인증: 사용자 JWT
- 요청: PathVariable `deviceId`
- 응답: `200 DeviceStatusResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| deviceId | UUID | 필수 | 기기 ID |
| status | String | 필수 | 상태 |
| recording | boolean | 필수 | 녹화 중 여부(MQTT heartbeat 기반, 기기 측 항상 false 스텁 — 3.5절 참고) |
| uploadQueueDepth | int | 필수 | 업로드 대기열 깊이(기기 측 항상 0 스텁) |
| bufferSeconds | Integer | 옵션(nullable) | 버퍼 초 |
| personCount | Integer | 옵션(nullable) | 인원 수 |
| checkedAt | Instant | 필수 | 조회 시각 |

- 에러: 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `getDeviceStatus`(#11) → `AppController.refreshDeviceData`
- 소스: `device/api/DeviceController.java`, `device/api/DeviceStatusResponse`

#### API-12 `POST /api/devices/{deviceId}/transfer-ownership`
- 인증: 사용자 JWT(OWNER)
- 요청

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| newOwnerMembershipId | UUID | 필수 | `@NotNull` |

- 응답: `204 No Content`
- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`, 409 `ALREADY_OWNER`, 409 `TRANSFER_TARGET_NOT_ACTIVE_MEMBER`
- 사용 상태: ✅ 사용됨 — frontend `transferOwnership`(#31, `FamilyScreen._MemberTile._transfer`가 `controller.api` 직접 호출)
- 소스: `device/api/DeviceController.java`, `device/api/TransferOwnershipRequest`

#### API-13 `DELETE /api/devices/{deviceId}`
- 인증: 사용자 JWT(OWNER)
- 요청: PathVariable `deviceId`
- 응답: `204 No Content`
- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `releaseDevice`(#32) → `SettingsScreen._releaseDevice`
- 소스: `device/api/DeviceController.java`

### 2.3 invitation 도메인 (API-14 ~ API-24)

기준 컨트롤러: `invitation/api/InvitationController.java`, Base path `/api`

#### API-14 `POST /api/devices/{deviceId}/invitations`
- 인증: 사용자 JWT(OWNER)
- 요청: `CreateInvitationRequest`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| email | String | 필수 | `@NotBlank @Email @Size≤320` |
| role | String | 필수 | `@NotBlank @Pattern "EDITOR\|VIEWER"` |
| membershipRequestToken | String | 옵션 | `@Size≤200` |

- 응답: `201 InvitationResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| id | UUID | 필수 | 초대 ID |
| deviceId | UUID | 필수 | 기기 ID |
| deviceName | String | 필수 | 기기 이름 |
| inviteeEmail | String | 필수 | 초대받는 이메일 |
| role | String | 필수 | EDITOR/VIEWER |
| inviter.id | UUID | 옵션(inviter nullable) | 초대자 ID |
| inviter.email | String | 옵션 | 초대자 이메일 |
| inviter.displayName | String | 옵션 | 초대자 표시이름 |
| status | String | 필수 | PENDING/ACCEPTED/DECLINED/EXPIRED/REVOKED |
| expiresAt | Instant | 필수 | 만료 시각 |
| createdAt | Instant | 필수 | 생성 시각 |

- 에러: 403 `FORBIDDEN_ROLE`, 422 `VALIDATION_FAILED`(role 아님), 409 `ALREADY_DEVICE_MEMBER`, 409 `INVITATION_PENDING`, 409 `MEMBERSHIP_REQUEST_EMAIL_MISMATCH`, 404 `MEMBERSHIP_REQUEST_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `createInvitation`(#22) → `FamilyScreen._sendInvitation`
- 소스: `invitation/api/InvitationController.java`, `invitation/application/InvitationService.java`, `invitation/application/MembershipRequestService.java`

#### API-15 `POST /api/membership-request-links`
- 인증: 사용자 JWT
- 요청: 없음
- 응답: `201 MembershipRequestLinkResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| token | String | 필수 | 요청 링크 토큰 |
| expiresAt | Instant | 필수 | 만료 시각 |

- 에러: 없음
- 사용 상태: ✅ 사용됨 — frontend `createMembershipRequestLink`(#23) → `DeviceRegistrationScreen._shareMembershipRequest`
- 소스: `invitation/api/InvitationController.java`, `invitation/application/MembershipRequestService.java`

#### API-16 `GET /api/membership-request-links/{token}`
- 인증: 사용자 JWT
- 요청: PathVariable `token`
- 응답: `200 MembershipRequestPreviewResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| email | String | 필수 | 요청자 이메일 |
| displayName | String | 필수 | 요청자 표시이름 |
| expiresAt | Instant | 필수 | 만료 시각 |

- 에러: 403 `OWNER_MEMBERSHIP_REQUIRED`, 404 `MEMBERSHIP_REQUEST_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `previewMembershipRequest`(#24) → `AppController.resolvePendingMembershipRequest`(딥링크 처리)
- 소스: `invitation/api/InvitationController.java`, `invitation/application/MembershipRequestService.java`

#### API-17 `GET /api/membership-request-links/{token}/open`
- 인증: 공개(permitAll)
- 요청: PathVariable `token`(정규식 `[A-Za-z0-9_-]{43}` 검증)
- 응답: `302 Redirect` (`Location: bbanggeut://membership-request/{token}`, 본문 없음)
- 에러: 형식 불일치 시 404(본문 없음, `ErrorResponse` 아님 — 딥링크 리다이렉트 전용 별도 로직)
- 사용 상태: 🔶 서버 구현·클라이언트 미사용 — `api_client.dart`에 `/open` 호출 없음. 이메일/공유 링크로 외부 브라우저가 열고, 앱은 리다이렉트 결과인 `bbanggeut://` 딥링크만 `app_links`로 수신
- 소스: `invitation/api/InvitationController.java`

#### API-18 `GET /api/devices/{deviceId}/invitations`
- 인증: 사용자 JWT(OWNER)
- 요청: PathVariable `deviceId`
- 응답: `200 List<InvitationResponse>` (API-14 응답 스키마와 동일)
- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `listDeviceInvitations`(#25) → `FamilyScreen`(보낸 초대)
- 소스: `invitation/api/InvitationController.java`

#### API-19 `DELETE /api/devices/{deviceId}/invitations/{invitationId}`
- 인증: 사용자 JWT(OWNER)
- 요청: PathVariable `deviceId`, `invitationId`
- 응답: `204 No Content`
- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`, 409 `INVITATION_NOT_PENDING`
- 사용 상태: ✅ 사용됨 — frontend `revokeInvitation`(#26) → `FamilyScreen._SentInvitationCard`
- 소스: `invitation/api/InvitationController.java`

#### API-20 `GET /api/invitations`
- 인증: 사용자 JWT
- 요청: 없음
- 응답: `200 List<InvitationResponse>`
- 에러: 없음
- 사용 상태: ✅ 사용됨 — frontend `listMyInvitations`(#27) → `InvitationInboxScreen`
- 소스: `invitation/api/InvitationController.java`

#### API-21 `POST /api/invitations/{invitationId}/accept`
- 인증: 사용자 JWT
- 요청: PathVariable `invitationId`
- 응답: `200 DeviceMemberResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| id | UUID | 필수 | 멤버십 ID |
| deviceId | UUID | 필수 | 기기 ID |
| user.id | UUID | 필수 | 사용자 ID |
| user.email | String | 필수 | 이메일 |
| user.displayName | String | 필수 | 표시이름 |
| role | String | 필수 | 역할 |
| status | String | 필수 | ACTIVE/REVOKED |
| joinedAt | Instant | 필수 | 가입 시각 |

- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `INVITATION_EXPIRED`, 409 `INVITATION_NOT_PENDING`
- 사용 상태: ✅ 사용됨 — frontend `acceptInvitation`(#28) → `InvitationInboxScreen._accept`
- 소스: `invitation/api/InvitationController.java`, `invitation/api/DeviceMemberResponse`

#### API-22 `POST /api/invitations/{invitationId}/decline`
- 인증: 사용자 JWT
- 요청: PathVariable `invitationId`
- 응답: `204 No Content`
- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `INVITATION_NOT_PENDING`
- 사용 상태: ✅ 사용됨 — frontend `declineInvitation`(#29) → `InvitationInboxScreen._decline`
- 소스: `invitation/api/InvitationController.java`

#### API-23 `GET /api/devices/{deviceId}/members`
- 인증: 사용자 JWT(멤버)
- 요청: PathVariable `deviceId`
- 응답: `200 List<DeviceMemberResponse>` (API-21 응답 스키마와 동일)
- 에러: 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `listMembers`(#20) → `FamilyScreen`
- 소스: `invitation/api/InvitationController.java`

#### API-24 `DELETE /api/devices/{deviceId}/members/{membershipId}`
- 인증: 사용자 JWT(OWNER)
- 요청: PathVariable `deviceId`, `membershipId`
- 응답: `204 No Content`
- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`, 409 `OWNER_CANNOT_BE_REVOKED`, 409 `MEMBERSHIP_NOT_ACTIVE`
- 사용 상태: ✅ 사용됨 — frontend `revokeMember`(#30) → `FamilyScreen._MemberTile._revoke`
- 소스: `invitation/api/InvitationController.java`

### 2.4 video 도메인 (API-25 ~ API-33)

기준 컨트롤러: `video/api/IotVideoController.java`(Base `/api/iot/videos`, 기기 credential), `video/api/VideoController.java`(Base `/api/videos`, 사용자 JWT), `video/api/VideoStatsController.java`(Base `/api/devices/{deviceId}/stats`, 사용자 JWT)

#### API-25 `POST /api/iot/videos/upload-url`
- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING)
- 요청: Header `Idempotency-Key`(필수, `sourceEventId`와 동일해야 함) + Body `IotUploadUrlRequest`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| sourceEventId | String | 필수 | `@NotBlank @Size≤100`, UUID 형식 |
| triggerType | String | 필수 | `@Pattern "LAUGHTER\|WAKE_WORD\|TOUCH\|MANUAL"` |
| title | String | 필수 | `@NotBlank @Size≤120` |
| capturedStartAt | Instant | 필수 | `@NotNull` |
| capturedEndAt | Instant | 필수 | `@NotNull` |
| durationMs | long | 필수 | `@Min 1` |
| contentType | String | 필수 | `@Pattern "video/mp4"` |
| sizeBytes | long | 필수 | `@Min 1`, 최대 500MiB |
| checksumSha256 | String | 필수 | `@Pattern [0-9a-f]{64}` |

- 응답: `200 IotUploadUrlResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| videoId | UUID | 필수 | 비디오 ID |
| alreadyCompleted | boolean | 필수 | 이미 업로드 완료된 idempotent 요청 여부 |
| uploadUrl | String | 옵션(nullable) | MinIO presigned PUT URL |
| method | String | 옵션(nullable) | `"PUT"` |
| requiredHeaders | Map<String,String> | 옵션(nullable) | 업로드 시 필요한 헤더(`x-amz-meta-sha256` 등) |
| expiresAt | Instant | 옵션(nullable) | URL 만료 시각 |

- 에러: 413 `VIDEO_TOO_LARGE`(500MiB 초과), 422 `VALIDATION_FAILED`, 409 `DEVICE_NOT_CLAIMED`, 409 `VIDEO_STATE_CONFLICT`, 409 `IDEMPOTENCY_KEY_MISMATCH`, 409 `IDEMPOTENCY_CONFLICT`, 503 `OBJECT_STORAGE_UNAVAILABLE`
- 사용 상태: ✅ 사용됨 — ai-edge `laughter_clip_uploader.py`/`segment_clip_uploader.py`
- 소스: `video/api/IotVideoController.java`, `video/application/IotVideoService.java`, `video/api/IotUploadUrlRequest`, `video/api/IotUploadUrlResponse` / (호출부) `ai/yolo/laughter_clip_uploader.py`, `ai/yolo/segment_clip_uploader.py`

#### API-26 `POST /api/iot/videos/complete`
- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING)
- 요청: Header `Idempotency-Key`(필수) + Body `IotUploadCompleteRequest`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| videoId | UUID | 필수 | `@NotNull` |
| objectETag | String | 옵션 | `@Size≤200` |

- 응답: `200 VideoResponse` (API-28 응답 스키마와 동일)
- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `VIDEO_STATE_CONFLICT`, 409 `IDEMPOTENCY_KEY_MISMATCH`, 409 `UPLOAD_INTEGRITY_MISMATCH`, 503 `OBJECT_STORAGE_UNAVAILABLE`
- 사용 상태: ✅ 사용됨 — ai-edge 동일 파일들, `{videoId, objectETag}`
- 소스: `video/api/IotVideoController.java`, `video/application/IotVideoService.java`

#### API-27 `GET /api/videos`
- 인증: 사용자 JWT
- 요청: RequestParam

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| deviceId | UUID | 필수 | 기기 ID |
| triggerType | String | 옵션 | 트리거 타입 필터 |
| from | Instant | 옵션 | 조회 시작 |
| to | Instant | 옵션 | 조회 종료 |
| cursor | String | 옵션 | 페이지 커서 |
| size | int | 옵션(기본 20) | 1~100 |

- 응답: `200 VideoPageResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| items | List\<VideoResponse\> | 필수 | 영상 목록(API-28 스키마) |
| nextCursor | String | 옵션(nullable) | 다음 페이지 커서 |
| hasNext | boolean | 필수 | 다음 페이지 존재 여부 |

- 에러: 422 `VALIDATION_FAILED`(size 범위/triggerType 미지원/from≥to), 404 `RESOURCE_NOT_FOUND`, 422 `INVALID_CURSOR`
- 사용 상태: ✅ 사용됨 — frontend `listVideos`(#14). 쿼리 `size` 범위 1~100 코드 대조 일치
- 소스: `video/api/VideoController.java`, `video/application/VideoQueryService.java`, `video/application/VideoCursorCodec.java`

#### API-28 `GET /api/videos/{videoId}`
- 인증: 사용자 JWT
- 요청: PathVariable `videoId`
- 응답: `200 VideoResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| id | UUID | 필수 | 비디오 ID |
| deviceId | UUID | 필수 | 기기 ID |
| sourceType | String | 필수 | IOT_CAPTURE/USER_UPLOAD/EDIT_OUTPUT |
| triggerType | String | 필수 | LAUGHTER/WAKE_WORD/TOUCH/MANUAL/USER_UPLOAD/EDIT |
| sourceEventId | String | 옵션(nullable) | 원본 이벤트 ID |
| title | String | 필수 | 제목 |
| description | String | 옵션(nullable) | 메모 |
| contentType | String | 필수 | 콘텐츠 타입 |
| sizeBytes | Long | 옵션(nullable) | 파일 크기 |
| checksumSha256 | String | 옵션(nullable) | 체크섬 |
| durationMs | Long | 옵션(nullable) | 길이(ms) |
| capturedStartAt | Instant | 옵션(nullable) | 촬영 시작 |
| capturedEndAt | Instant | 옵션(nullable) | 촬영 종료 |
| status | String | 필수 | UPLOADING/PROCESSING/READY/FAILED/DELETING/DELETED |
| isFavorite | boolean | 필수 | 즐겨찾기 여부 |
| thumbnailUrl | String | 옵션(nullable) | ⚠️ 코드상 항상 null로 채워짐(썸네일 생성 로직 존재 여부 미확인) |
| createdAt | Instant | 필수 | 생성 시각 |

- 에러: 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `getVideo`(#19)
- 소스: `video/api/VideoController.java`, `video/api/VideoResponse`

#### API-29 `PATCH /api/videos/{videoId}`
- 인증: 사용자 JWT(OWNER/EDITOR)
- 요청: `UpdateVideoRequest`(class, partial update)

| 필드명(JSON 키) | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| title | String | 옵션(titlePresent) | 제목 |
| description | String | 옵션(descriptionPresent) | 메모 |
| isFavorite | Boolean | 옵션(favoritePresent, 내부 필드명 `favorite`) | 즐겨찾기 여부 |

- 응답: `200 VideoResponse` (API-28 스키마)
- 에러: 403 `FORBIDDEN_ROLE`("OWNER 또는 EDITOR 권한이 필요합니다"), 404 `RESOURCE_NOT_FOUND`, 422 `VALIDATION_FAILED`
- 사용 상태: ✅ 사용됨 — frontend `updateVideo`(#17, `{title?,description?,isFavorite?}`) — JSON 키가 `UpdateVideoRequest`와 일치
- 소스: `video/application/VideoCommandService.java`, `video/api/UpdateVideoRequest`

#### API-30 `DELETE /api/videos/{videoId}`
- 인증: 사용자 JWT(OWNER)
- 요청: PathVariable `videoId`
- 응답: `202 Accepted`(No Content, 비동기 삭제 큐 등록)
- 에러: 403 `FORBIDDEN_ROLE`("OWNER만 영상을 삭제할 수 있습니다"), 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `deleteVideo`(#18) → `AppController.removeVideo` → `VideosScreen._confirmDelete`
- 소스: `video/application/VideoCommandService.java`

#### API-31 `POST /api/videos/{videoId}/play-url`
- 인증: 사용자 JWT
- 요청: PathVariable `videoId`
- 응답: `200 SignedUrlResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| url | String | 필수 | MinIO presigned GET URL(재생용) |
| expiresAt | Instant | 필수 | 만료 시각 |

- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `VIDEO_NOT_READY`, 503 `OBJECT_STORAGE_UNAVAILABLE`
- 사용 상태: ✅ 사용됨 — frontend `createPlayUrl`(#15) → `VideoDetailScreen._load`
- 소스: `video/application/VideoQueryService.java`, `video/api/SignedUrlResponse`

#### API-32 `POST /api/videos/{videoId}/download-url`
- 인증: 사용자 JWT
- 요청: PathVariable `videoId`
- 응답: `200 SignedUrlResponse` (API-31과 동일 스키마, 다운로드 시 `response-content-disposition=attachment` 쿼리 추가된 URL)
- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `VIDEO_NOT_READY`, 503 `OBJECT_STORAGE_UNAVAILABLE`
- 사용 상태: ✅ 사용됨 — frontend `createDownloadUrl`(#16) → `VideoDetailScreen._download`, `LocalEditScreen._downloadSource`
- 소스: `video/application/VideoQueryService.java`

#### API-33 `GET /api/devices/{deviceId}/stats`
- 인증: 사용자 JWT
- 요청: RequestParam `from`,`to`(LocalDate, 옵션), `timeZone`(옵션)
- 응답: `200 VideoStatsResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| deviceId | UUID | 필수 | 기기 ID |
| from | LocalDate | 필수 | 조회 시작일 |
| to | LocalDate | 필수 | 조회 종료일 |
| timeZone | String | 필수 | 타임존 |
| totalCount | long | 필수 | 총 영상 수 |
| byTriggerType | List\<NamedCount\> | 필수 | 트리거 타입별 집계(`name`,`count`) |
| dailyCounts | List\<DailyCount\> | 필수 | 일별 집계(`date`,`count`) |
| peakWeekday | NamedCount | 옵션(nullable) | 최다 요일(`name`,`count`) |
| peakHour | NamedCount | 옵션(nullable) | 최다 시간대(`name`,`count`) |

- 에러: 404 `RESOURCE_NOT_FOUND`, 422 `VALIDATION_FAILED`(기간/timeZone)
- 사용 상태: ✅ 사용됨 — frontend `getVideoStats`(#12) → `HomeScreen`, `LaughReportScreen`
- 소스: `video/api/VideoStatsController.java`, `video/application/VideoStatsService.java`

### 2.5 stream·live 도메인 (API-34 ~ API-38)

기준 컨트롤러: `stream/api/LiveIntrospectionController.java`, `stream/api/StreamController.java`

#### API-34 `GET /api/live/introspect`
- 인증: 공개(permitAll) — `token` 자체 서명 검증
- 요청: RequestParam `token`, `streamId`
- 응답: `204 No Content`(재생 허용)
- 에러: 401(본문 없음, 재생 불허)
- 사용 상태: 🔶 서버 구현·클라이언트 미사용 — frontend/ai-edge 코드에 호출 없음. MediaMTX가 재생 인가 확인을 위해 호출하는 것으로 추정(⚠️ 미확인: 호출 주체는 코드상 확인 불가)
- 소스: `stream/api/LiveIntrospectionController.java`, `stream/application/StreamService.java`, `stream/application/LiveTokenService.java`

#### API-35 `POST /api/devices/{deviceId}/stream-sessions`
- 인증: 사용자 JWT
- 요청: PathVariable `deviceId`
- 응답: `202 Accepted StreamSessionResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| sessionId | UUID | 필수 | 세션 ID |
| streamId | UUID | 필수 | 스트림 ID |
| deviceId | UUID | 필수 | 기기 ID |
| status | String | 필수 | PENDING/READY/FAILED/CLOSED/EXPIRED |
| playUrl | String | 옵션(nullable) | 재생 URL(HLS, `READY` 상태에서 값 존재) |
| heartbeatIntervalSeconds | int | 필수 | 하트비트 주기(초) |
| viewerExpiresAt | Instant | 필수 | 뷰어 세션 만료 시각 |
| edgeHardExpiresAt | Instant | 필수 | 기기측 하드 만료 시각 |
| failureCode | String | 옵션(nullable) | 실패 코드 |
| createdAt | Instant | 필수 | 생성 시각 |

- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `DEVICE_OFFLINE`
- 사용 상태: ✅ 사용됨 — frontend `createStream`(#33) → `EmbeddedLivePlayer._start`(`HomeScreen` 실사용), `LiveScreen._start`(미사용 화면)
- 소스: `stream/api/StreamController.java`, `stream/application/StreamService.java`

#### API-36 `GET /api/stream-sessions/{sessionId}`
- 인증: 사용자 JWT
- 요청: PathVariable `sessionId`
- 응답: `200 StreamSessionResponse` (API-35와 동일 스키마)
- 에러: 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `getStream`(#34) → 상태 폴링(2초 간격)
- 소스: `stream/api/StreamController.java`

#### API-37 `DELETE /api/stream-sessions/{sessionId}`
- 인증: 사용자 JWT
- 요청: PathVariable `sessionId`
- 응답: `204 No Content`
- 에러: 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `closeStream`(#36)
- 소스: `stream/api/StreamController.java`

#### API-38 `POST /api/stream-sessions/{sessionId}/heartbeat`
- 인증: 사용자 JWT
- 요청: PathVariable `sessionId`
- 응답: `204 No Content`
- 에러: 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `heartbeatStream`(#35)
- 소스: `stream/api/StreamController.java`

### 2.6 subscription 도메인 (API-39 ~ API-41)

기준 컨트롤러: `subscription/api/SubscriptionController.java`, Base path `/api/devices/{deviceId}/subscription`

#### API-39 `GET /api/devices/{deviceId}/subscription`
- 인증: 사용자 JWT
- 요청: PathVariable `deviceId`
- 응답: `200 SubscriptionResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| deviceId | UUID | 필수 | 기기 ID |
| active | boolean | 필수 | 구독 활성 여부 |
| graceUntil | Instant | 옵션(nullable) | 유예기간 종료 시각 |
| premiumRetentionDays | int | 필수 | 프리미엄 보관 기간(일) |

- 에러: 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `getSubscription`(#37) → `SettingsScreen._subscription`
- 소스: `subscription/api/SubscriptionController.java`, `subscription/api/SubscriptionResponse`

#### API-40 `PUT /api/devices/{deviceId}/subscription`
- 인증: 사용자 JWT(OWNER)
- 요청: PathVariable `deviceId`(본문 없음, 코드상 body 파라미터 없음)
- 응답: `200 SubscriptionResponse` (API-39와 동일 스키마)
- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`
- 사용 상태: ✅ 사용됨 — frontend `activateSubscription`(#38)
- 소스: `subscription/api/SubscriptionController.java`

#### API-41 `DELETE /api/devices/{deviceId}/subscription`
- 인증: 사용자 JWT(OWNER)
- 요청: PathVariable `deviceId`
- 응답: `200 SubscriptionResponse`
- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`, 409 `SUBSCRIPTION_NOT_ACTIVE`
- 사용 상태: ✅ 사용됨 — frontend `cancelSubscription`(#39)
- 소스: `subscription/api/SubscriptionController.java`

### 2.7 home 도메인 (API-42)

#### API-42 `GET /api/devices/{deviceId}/home-summary`
- 인증: 사용자 JWT
- 요청: PathVariable `deviceId`; RequestParam `timeZone`(옵션)
- 응답: `200 HomeSummaryResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| deviceId | UUID | 필수 | 기기 ID |
| date | LocalDate | 필수 | 기준 날짜 |
| timeZone | String | 필수 | 타임존 |
| captureCount | long | 필수 | 촬영(감지) 수 |
| savedCount | long | 필수 | 저장된 영상 수 |
| memoCount | long | 필수 | 메모 수 |
| latestHighlight | VideoResponse | 옵션(nullable) | 최근 하이라이트 영상(API-28 스키마) |

- 에러: 404 `RESOURCE_NOT_FOUND`, 422 `VALIDATION_FAILED`(지원하지 않는 timeZone)
- 사용 상태: ✅ 사용됨 — frontend `getHomeSummary`(#13) → `AppController._loadHomeSummary` → `HomeScreen`
- 소스: `home/api/HomeSummaryController.java`, `home/application/HomeSummaryService.java`

### 2.8 iot 도메인 (API-43 ~ API-46)

#### API-43 `POST /api/iot/registration-codes`
- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING)
- 요청: `@AuthenticationPrincipal DevicePrincipal`(본문 없음)
- 응답: `200 RegistrationCodeResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| registrationCode | String | 필수 | 화면 표시용 등록 코드 |
| expiresAt | Instant | 필수 | 만료 시각(2분, ai-edge.md 근거) |

- 에러: 409 `DEVICE_ALREADY_CLAIMED`
- 사용 상태: ✅ 사용됨 — ai-edge `wj_device_agent/provision.py`(`registration-code` 서브커맨드) → `registration-button.sh` 경유
- 소스: `device/api/IotRegistrationController.java`, `device/application/RegistrationCodeService.java` / (호출부) `ai/device_agent/wj_device_agent/provision.py`

#### API-44 `POST /api/iot/enrollment`
- 인증: 기기 credential(Bearer, ROLE_DEVICE_BOOTSTRAP)
- 요청: `@AuthenticationPrincipal DevicePrincipal`(본문 없음)
- 응답: `200 ProvisionedDeviceResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| deviceId | UUID | 필수 | 기기 ID |
| serialNumber | String | 옵션(nullable) | 시리얼 번호 |
| keyId | String | 필수 | 자격증명 키 ID |
| bearerToken | String | 필수 | `{keyId}.{secret}` 형식 |
| purpose | String | 필수 | `"BOOTSTRAP"` \| `"OPERATING"` |
| expiresAt | Instant | 필수 | 자격증명 만료 시각 |
| mqttUsername | String | 옵션(OPERATING일 때만 값 존재) | MQTT 계정명 |

- 에러: 404 `RESOURCE_NOT_FOUND`, 401 `DEVICE_CREDENTIAL_STALE`, 403 `DEVICE_CREDENTIAL_PURPOSE_INVALID`
- 사용 상태: ✅ 사용됨 — ai-edge `DeviceApi.enroll`(`provision.py`)
- 소스: `iot/auth/DeviceCredentialController.java`, `provisioning/application/ProvisioningService.java`

#### API-45 `POST /api/iot/credentials/rotate`
- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING)
- 요청: `@AuthenticationPrincipal DevicePrincipal`(본문 없음)
- 응답: `200 ProvisionedDeviceResponse` (API-44와 동일 스키마)
- 에러: 404 `RESOURCE_NOT_FOUND`, 401 `DEVICE_CREDENTIAL_STALE`, 403 `DEVICE_CREDENTIAL_PURPOSE_INVALID`
- 사용 상태: ✅ 사용됨 — ai-edge `DeviceApi.rotate`(`provision.py`)
- 소스: `iot/auth/DeviceCredentialController.java`, `provisioning/application/ProvisioningService.java`

#### API-46 `GET /api/devices/{deviceId}/event-stats`
- 인증: 사용자 JWT
- 요청: PathVariable `deviceId`; RequestParam `from`,`to`(LocalDate, ISO, 옵션), `timeZone`(옵션)
- 응답: `200 EventStatsResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| deviceId | UUID | 필수 | 기기 ID |
| from | LocalDate | 필수 | 조회 시작일 |
| to | LocalDate | 필수 | 조회 종료일 |
| timeZone | String | 필수 | 타임존 |
| detectedCount | long | 필수 | 감지된 이벤트 수 |
| uploadedVideoCount | long | 필수 | 업로드된 영상 수 |
| byType | List\<NamedCount\> | 필수 | 타입별 집계(`name`,`count`) |
| dailyCounts | List\<DailyCount\> | 필수 | 일별 집계(`date`,`count`) |

- 에러: 404 `RESOURCE_NOT_FOUND`, 422 `VALIDATION_FAILED`(from>to 또는 기간 366일 초과, 지원하지 않는 timeZone)
- 사용 상태: 🔶 서버 구현·클라이언트 미사용 — `api_client.dart`에 `event-stats` 문자열 자체가 없음. `LaughReportScreen`은 `VideoStatsController`(API-33)만 사용. ai-edge도 미호출
- 소스: `iot/event/EventStatsController.java`, `iot/event/EventStatsService.java`

### 2.9 provisioning 도메인 (API-47 ~ API-49)

기준 컨트롤러: `provisioning/api/ProvisioningController.java`, Base path `/internal/admin/devices` — **내부 관리자 키**(`X-Provisioning-Key` + loopback IP)

#### API-47 `POST /internal/admin/devices`
- 인증: 내부 키
- 요청: `ProvisionDeviceRequest`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| serialNumber | String | 필수 | `@NotBlank @Size≤80` |
| name | String | 필수 | `@NotBlank @Size≤80` |
| model | String | 필수 | `@NotBlank @Size≤80` |
| firmwareVersion | String | 옵션 | `@Size≤40` |

- 응답: `201 ProvisionedDeviceResponse` (API-44 스키마와 동일)
- 에러: 409 `DEVICE_SERIAL_ALREADY_ACTIVE`
- 사용 상태: 🔶 서버 구현·클라이언트 미사용 — 내부 관리자 키(loopback) 전용, frontend/ai-edge 코드 어디에도 호출 없음(사람이 서버에서 curl 등으로 호출하는 운영 절차로 추정)
- 소스: `provisioning/api/ProvisioningController.java`, `provisioning/application/ProvisioningService.java`

#### API-48 `POST /internal/admin/devices/{deviceId}/credentials/rotate`
- 인증: 내부 키
- 요청: PathVariable `deviceId`
- 응답: `200 ProvisionedDeviceResponse`
- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `DEVICE_REVOKED`
- 사용 상태: 🔶 서버 구현·클라이언트 미사용(상동)
- 소스: `provisioning/api/ProvisioningController.java`, `provisioning/application/ProvisioningService.java`

#### API-49 `DELETE /internal/admin/devices/{deviceId}/credentials`
- 인증: 내부 키
- 요청: PathVariable `deviceId`
- 응답: `204 No Content`
- 에러: 404 `RESOURCE_NOT_FOUND`
- 사용 상태: 🔶 서버 구현·클라이언트 미사용(상동)
- 소스: `provisioning/api/ProvisioningController.java`

인증 실패(키 불일치/비-loopback/`app.provisioning.enabled=false`) 시 필터 단계에서 404 `RESOURCE_NOT_FOUND`로 응답(엔드포인트 존재 자체를 숨김) — `ProvisioningAuthenticationFilter`.

### 2.10 audit 도메인 (API-50)

#### API-50 `GET /api/devices/{deviceId}/access-logs`
- 인증: 사용자 JWT
- 요청: PathVariable `deviceId`; RequestParam `cursor`(옵션), `size`(기본 20)
- 응답: `200 AccessLogPageResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| items | List\<AccessLogResponse\> | 필수 | 접근 로그 목록 |
| nextCursor | String | 옵션(nullable) | 다음 페이지 커서 |
| hasNext | boolean | 필수 | 다음 페이지 존재 여부 |
| items[].id | long | 필수 | 로그 ID |
| items[].deviceId | UUID | 필수 | 기기 ID |
| items[].actorUserId | UUID | 옵션(nullable) | 행위자 사용자 ID |
| items[].actorDeviceId | UUID | 옵션(nullable) | 행위자 기기 ID |
| items[].action | String | 필수 | `audit_action` enum(MEMBER_INVITE 등) |
| items[].targetType | String | 필수 | 대상 타입 |
| items[].targetId | UUID | 옵션(nullable) | 대상 ID |
| items[].outcome | String | 필수 | SUCCESS/DENIED/FAILED |
| items[].reasonCode | String | 옵션(nullable) | 사유 코드 |
| items[].createdAt | Instant | 필수 | 발생 시각 |

- 에러: 422 `VALIDATION_FAILED`(size 1~100 범위 아님), 403 `FORBIDDEN_ROLE`(OWNER 아님), 404 `RESOURCE_NOT_FOUND`, 422 `INVALID_CURSOR`(커서 손상)
- 사용 상태: ✅ 사용됨 — frontend `listAccessLogPage`(#40) → `listAccessLogs`(#41, 커서 반복 수집) → `SettingsScreen._logs`
- 소스: `audit/api/AccessLogController.java`, `audit/application/AccessLogQueryService.java`, `audit/application/AccessLogCursorCodec.java`

---

## 3. MQTT 토픽 명세

MQTT 항목 수 = cross-check의 15행(`wj/v2` baseline 9 + `homecam/v2` 6) = **15개**. MQTT-01부터 순번을 부여했다. 토픽 베이스: `${app.mqtt.environment}/wj/v2`(예: `local/wj/v2`, `prod/wj/v2`), 브로커: Mosquitto + `dynamic-security` 플러그인.

> **v2 마이그레이션(커밋 `692453b`)**: 토픽 루트가 `wj/v1`→`wj/v2`, `schemaVersion`이 `1.0`→`2.0`으로 변경됐다. 백엔드 `MqttInboundHandler`는 `2.0`이 아닌 payload를 조용히 폐기하므로 구버전 예시를 복사하면 안 된다. 기존 기기의 브로커 ACL은 백엔드 시작 시 `MqttTopicAclMigrationWorker`(`iot/mqtt/MqttTopicAclMigrationWorker.java`)가 v1·v2 ACL을 모두 제거한 뒤 v2로 재부여하는 방식으로 자동 이관된다(`PahoMqttGateway.migrateTopicAcl`).

### 3.1 요약표

| ID | 토픽(접미사) | 방향 | 발행자/구독자 | QoS | 상태 |
|---|---|---|---|---|---|
| MQTT-01 | `{base}/devices/{deviceId}/commands` | 발행(백엔드→기기) | 발행: 백엔드(`StreamCommandPublisher`) / 구독: 기기(`agent.py`) | 1(retained=false) | ✅ (기기측 PING 처리분기는 죽은 코드 — 3.2절) |
| MQTT-02 | `{base}/devices/+/status` | 구독(기기→백엔드) | 발행: 기기 / 구독: 백엔드(`MqttInboundHandler`) | 1 | ⚠️ 스키마 불일치 |
| MQTT-03 | `{base}/devices/+/commands/ack` | 구독(기기→백엔드) | 발행: 기기 / 구독: 백엔드 | 1 | ⚠️ 스키마 불일치 |
| MQTT-04 | `{base}/devices/+/stream/events` | 구독(기기→백엔드) | 발행: 기기 / 구독: 백엔드 | 1 | ⚠️ 스키마 불일치(타입 누락) |
| MQTT-05 | `{base}/devices/+/heartbeat` | 구독(기기→백엔드) | 발행: 기기 / 구독: 백엔드 | 0 | ⚠️ 스키마 불일치(스텁 값) |
| MQTT-06 | `{base}/devices/+/registration` | 구독(기기→백엔드) | 구독: 백엔드만(기기 발행 없음) | 1 | 🔶 서버 구현·기기 미발행 |
| MQTT-07 | `{base}/devices/+/events` | 구독(기기→백엔드) | 구독: 백엔드만(기기 발행 없음) | 1 | 🔶 서버 구현·기기 미발행 |
| MQTT-08 | `$CONTROL/dynamic-security/v1` | 발행(백엔드→브로커) | 발행: 백엔드 / 대상: 브로커(dynsec) | 1 | 해당없음(브로커 관리 채널) |
| MQTT-09 | `$CONTROL/dynamic-security/v1/response` | 구독(브로커→백엔드) | 발행: 브로커 / 구독: 백엔드 | 1 | 해당없음(브로커 관리 채널) |
| MQTT-10 | `homecam/v2/{device_id}/ai/vision/state` | 발행(YOLO)/구독(event_fusion, 내부) | 발행: `vision_mqtt_publisher.py` / 구독: `event_fusion_service.py`(백엔드 아님) | 0 | 🔴 백엔드 미구독 |
| MQTT-11 | `homecam/v2/{device_id}/control/framing/target` | 발행(YOLO) | 발행: `vision_mqtt_publisher.py` / 구독자 전무 | 0 | 🔴 백엔드 미구독·구독자 전무 |
| MQTT-12 | `homecam/v2/{device_id}/ai/vision/status` | 발행(YOLO, LWT) | 발행: `vision_mqtt_publisher.py` | 1(retain) | 🔴 백엔드 미구독 |
| MQTT-13 | `homecam/v2/{device_id}/ai/laughter/detected` | 발행(YAMNet)/구독(event_fusion, 내부) | 발행: `mqtt_event_publisher.py` / 구독: `event_fusion_service.py` | 1 | 🔴 백엔드 미구독 |
| MQTT-14 | `homecam/v2/{device_id}/ai/status` | 발행(YAMNet, LWT) | 발행: `mqtt_event_publisher.py` | 1(retain) | 🔴 백엔드 미구독 |
| MQTT-15 | `homecam/v2/{device_id}/events/memory-candidate` | 발행(event_fusion) | 발행: `event_fusion_service.py` | 1 | 🔴 백엔드 미구독 |

### 3.2 상세

#### MQTT-01 `{base}/devices/{deviceId}/commands`
- 페이로드: `{schemaVersion:"2.0", requestId, deviceId, type: START_STREAM|EXTEND_STREAM|STOP_STREAM, issuedAt, expiresAt(issuedAt+15s), payload}` — `START_STREAM.payload={sessionId,streamId,profile:"LIVE_720P_H264_AAC",segmentDurationSeconds:2,hardExpiresAt}`, `EXTEND_STREAM.payload={streamId,hardExpiresAt}`, `STOP_STREAM.payload={streamId,reason}`
- 트리거: 백엔드가 스트림 세션 생성/연장/종료 시 발행
- 상태: ✅ — 단, 기기(`agent.py`)는 이 3개 외 `PING`도 처리 가능하나 백엔드 Java 코드 전체(grep) 어디에도 `PING` 발행 코드가 없음(기기 쪽 죽은 코드 경로)
- 소스: `iot/mqtt/PahoMqttGateway.java`, `stream/application/StreamCommandPublisher.java`, `stream/application/StreamService.java` / `ai/device_agent/wj_device_agent/agent.py:103`

#### MQTT-02 `{base}/devices/+/status`
- 백엔드 구독 스키마: `{schemaVersion, deviceId, state: ONLINE|OFFLINE, firmwareVersion?}`(`state`/`firmwareVersion`만 읽음)
- 기기 실제 발행: `{schemaVersion, deviceId, state, reason(BOOT_COMPLETED|CONNECTION_LOST|SERVICE_STOPPED), firmwareVersion, occurredAt}`
- 트리거: 연결 성공(ONLINE), LWT(CONNECTION_LOST), 정상 종료(SERVICE_STOPPED)
- 상태: ⚠️ — `reason`, `occurredAt`은 백엔드가 파싱/저장하지 않고 버려짐(에러는 없음). retain=true(기기측)에 대한 백엔드 처리 방식은 ⚠️ 미확인
- 소스: `iot/telemetry/MqttInboundHandler.java:105-111` / `agent.py:71-76,92,104`

#### MQTT-03 `{base}/devices/+/commands/ack`
- 백엔드: `requestId`,`status`만 검증해 로그만 남김(`log.debug`, 상태 저장 없음)
- 기기 실제 발행: `schemaVersion,requestId,deviceId,status(ACCEPTED|SUCCEEDED|FAILED|REJECTED|EXPIRED),errorCode,message,occurredAt,streamId?,sessionId?`
- 트리거: 명령 수신·처리마다(중복 requestId는 캐시된 ack 재전송)
- 상태: ⚠️ — `errorCode`,`message`,`occurredAt`,`streamId`,`sessionId`는 백엔드가 전혀 읽지 않음
- 소스: `iot/telemetry/MqttInboundHandler.java`(`commandAck()`) / `agent.py:133,237-262`

#### MQTT-04 `{base}/devices/+/stream/events`
- 백엔드 스키마: `{schemaVersion, deviceId, streamId, type: STREAM_READY|STREAM_ERROR|STREAM_HARD_EXPIRED|STREAM_STOPPED, hardExpiresAt?, errorCode?}`
- 기기 실제 발행: `type`에 `STREAM_STARTING` 포함 5종 + `eventId,requestId,occurredAt,sessionId?` 추가 필드
- 트리거: 스트림 상태 전이 시(시작/준비완료/오류/중지/하드만료)
- 상태: ⚠️ — 백엔드 `streamEvent()` switch문은 `STREAM_STARTING`을 `default -> {}`로 조용히 무시(기기의 스트림 시작 알림이 반영되지 않음). `eventId`,`requestId`,`occurredAt`,`sessionId`도 미사용
- 소스: `iot/telemetry/MqttInboundHandler.java`(`streamEvent()`), `stream/application/StreamEventService.java` / `agent.py:264-285`

#### MQTT-05 `{base}/devices/+/heartbeat`
- 백엔드가 읽는 필드: `recording`,`uploadQueueDepth`(기본 0),`bufferSeconds?`,`personCount?`,`firmwareVersion`
- 기기 실제 발행: `schemaVersion,deviceId,sentAt,uptimeSeconds,recording(항상 false 고정),uploadQueueDepth(항상 0 고정),clockUnsynced(항상 false 고정),firmwareVersion,nodes:[{nodeId,online:true}],streaming`
- 트리거: 30초 주기
- 상태: ⚠️ — `recording`/`uploadQueueDepth`는 필드명은 일치하나 항상 스텁 값이라 `devices.recording`/`devices.upload_queue_depth`에 실제 상태 미반영. `bufferSeconds`/`personCount`는 기기가 보내지 않아 항상 null 기록(선택 필드라 프로토콜 위반 아님). `sentAt`,`uptimeSeconds`,`clockUnsynced`,`nodes`,`streaming`은 백엔드가 읽지 않는 잉여 필드
- 소스: `iot/telemetry/MqttInboundHandler.java`(`heartbeat()`) / `agent.py:211-225`

#### MQTT-06 `{base}/devices/+/registration`
- 백엔드 스키마: `{schemaVersion, deviceId, mode: ENABLED|DISABLED, expiresAt?}`(ENABLED는 만료 5분 이내일 때만 반영)
- 트리거: (설계상) 등록 모드 진입/해제 시 — 실제로는 발행자가 없음
- 상태: 🔶 서버 구현·기기 미발행 — 등록 코드 발급은 API-43(`POST /api/iot/registration-codes`) HTTP 경로로만 이루어짐
- 소스: `iot/telemetry/MqttInboundHandler.java:90-103`

#### MQTT-07 `{base}/devices/+/events`
- 백엔드 스키마: `{schemaVersion, deviceId, eventId, type: LAUGHTER|WAKE_WORD|TOUCH|MANUAL, occurredAt, confidence?(0~1, LAUGHTER/WAKE_WORD 필수, TOUCH/MANUAL 금지), localClip:{state,beforeMs,afterMs,mergeWindowMs}, source:{nodeId,component,modelVersion?}}`
- 트리거: (설계상) 기기 감지 이벤트 발생 시 — 실제 발행자 없음
- 상태: 🔶 서버 구현·기기 미발행 — 웃음 감지→업로드 흐름은 이 토픽 없이 API-25/26(HTTP)만으로 동작, `device_events` 테이블(V18) 사실상 미사용
- 소스: `iot/telemetry/MqttInboundHandler.java`(`detectionEvent()`), `iot/event/DeviceEventService.java`

#### MQTT-08 `$CONTROL/dynamic-security/v1`
- 페이로드: `{commands:[{command: createClient|createRole|addRoleACL|addClientRole|modifyClient|enableClient|getClient|disableClient|deleteClient|deleteRole, ...}]}`
- 트리거: 기기별 MQTT 계정/ACL 생성·회전·비활성화 시
- 상태: 해당없음 — 기기/프런트와 무관한 브로커 관리 채널(Mosquitto dynamic-security 플러그인)
- 소스: `iot/mqtt/PahoMqttGateway.java`

#### MQTT-09 `$CONTROL/dynamic-security/v1/response`
- 페이로드: dynsec 커맨드 응답(JSON)
- 트리거: MQTT-08 발행에 대한 브로커 응답
- 상태: 해당없음
- 소스: `iot/mqtt/PahoMqttGateway.java`

#### MQTT-10 `homecam/v2/{device_id}/ai/vision/state`
- 페이로드(`CameraCommand.as_payload()`): `state,direction,target_ids,target_count,total_stable_objects,center_x/y,error_x/y,group_box,limited_group,frame_index,schema_version,sequence,sent_at,ttl_ms,created_at,monotonic_ns,device_id,object_counts,track_ids`
- 트리거: `--command-interval`(기본 0.2초)마다, 타겟 변화 시
- 상태: 🔴 — 백엔드 구독 없음(`homecam` 키워드 grep 0건). `event_fusion_service.py` 구독은 AI 파이프라인 내부 프로세스 간 통신이지 백엔드가 아님
- 소스: `ai/yolo/vision_mqtt_publisher.py:31`, `ai/yolo/yolov8_autoframe_jetson.py:82-97`

#### MQTT-11 `homecam/v2/{device_id}/control/framing/target`
- 페이로드: vision/state와 동일 내용 재발행
- 트리거: 위와 동일
- 상태: 🔴 — 구독자 전무(백엔드도, 저장소 내 다른 코드도 미구독; 서보 제어기 미구현)
- 소스: `ai/yolo/vision_mqtt_publisher.py:126-131`

#### MQTT-12 `homecam/v2/{device_id}/ai/vision/status`
- 페이로드: `{device_id, component:"yolo", status:"online"/"offline"}`
- 트리거: 연결/종료 시(LWT 포함)
- 상태: 🔴 — 백엔드 구독 없음
- 소스: `ai/yolo/vision_mqtt_publisher.py:35,47-54,92-99`

#### MQTT-13 `homecam/v2/{device_id}/ai/laughter/detected`
- 페이로드: `schema_version,event_id,device_id,event_type:"laughter",detected_at,monotonic_ns,score,class_name,clip:{pre_seconds:60,post_seconds:60},model:{name:"YAMNet",threshold,consecutive}`
- 트리거: 웃음 판정 트리거 시
- 상태: 🔴 — 백엔드 구독 없음(웃음 감지 알림은 이 토픽이 아니라 API-25/26 HTTP 업로드로 대체 운영)
- 소스: `ai/yamnet/mqtt_event_publisher.py:36,113-154`

#### MQTT-14 `homecam/v2/{device_id}/ai/status`
- 페이로드: `{device_id, component:"yamnet", status:"online"/"offline"}`
- 트리거: 연결/종료 시
- 상태: 🔴 — 백엔드 구독 없음
- 소스: `ai/yamnet/mqtt_event_publisher.py:38`

#### MQTT-15 `homecam/v2/{device_id}/events/memory-candidate`
- 페이로드: 원본 laughter 이벤트 + `schema_version:"1.1",fused_at,source_schema_version,vision_context:{available,age_ms,object_count,track_ids,person_count,cat_count,dog_count,target_ids,target_count,total_stable_objects,camera_state,camera_direction,error_x,error_y,limited_group}`
- 트리거: laughter 이벤트 수신 시(vision_state 나이가 `--max-vision-age-ms` 기본 2000ms 이내면 컨텍스트 부착)
- 상태: 🔴 — 백엔드 구독 없음
- 소스: `ai/yolo/event_fusion_service.py:67-120,170-243`

### 3.3 MQTT-10~15 공통 비고

MQTT-10~15(`homecam/v2/*`)는 운영 배포 스크립트(`run_edge_ai_mvp.sh`/`run_edge_ai_recording.sh`)가 `MQTT_HOST=`(빈 값)로 넘겨 코드 경로 자체가 비활성화된 **실험 단계 산출물**이다. 젯슨 systemd 서비스 주석에 "wj-device-agent가 프로비저닝된 MQTT 아이덴티티의 유일한 소유자로 남는다"라고 명시되어 있어, 운영 결함이 아니라 구조적으로 분리된 미완성 파이프라인으로 해석해야 한다. `run_ai_stack.sh`(로컬 `localhost` mosquitto 대상 수동 검증 스크립트)에서만 사용이 확인된다.

기기별 MQTT 계정 ACL(`PahoMqttGateway.create`)은 `publishClientSend`를 `status,heartbeat,registration,events,stream/events,commands/ack`에, `subscribeLiteral`+`publishClientReceive`를 `commands`에 부여 — 즉 기기는 `wj/v2` 네임스페이스의 위 6개 토픽만 발행 가능하고 `commands`만 구독 가능하도록 브로커 레벨에서 제한되어 있다(`homecam/v2`은 이 ACL 체계 밖).

---

## 4. 미디어 경로

### 4.1 RTSPS publish (Jetson → MediaMTX)

- **송출 트리거**: 기기(`agent.py`)가 MQTT-01(`commands`)로 `START_STREAM`을 수신하면 `StreamManager.start(stream_id, hard_expires_at)` 실행
- **송출 대상 URL 구성**(`wj_device_agent/configure_media.py` `build_publish_url`): `rtsps://{quote(username)}:{quote(password)}@{host}:{port}/live/{stream_id}` — 기본 host `i15e201.p.ssafy.io`, 기본 port `8322`(`configure_media.py` CLI 기본값). `config.py`가 템플릿이 `rtsp://`/`rtsps://`로 시작하고 `{stream_id}`를 정확히 1개 포함하는지 검증. **`rtsps://` 템플릿은 추가 강제 검증(커밋 `0d3a96c`)**: 자격증명(username:password) 포함 + 경로 `/live/{stream_id}` 고정 + 쿼리/프래그먼트 금지 + `MEDIA_TLS_CA_CERT` 환경변수 필수(ffmpeg 출력에 TLS CA 적용). MediaMTX 쪽은 `rtspsAddress :8322`, `rtspEncryption: optional`(직접 RTSPS·앱 재생 검증 후 `strict` 전환 예정), 계정은 compose가 `infra/.env`에서 주입(`backend/deploy/mediamtx.yml`, `backend/deploy/MEDIAMTX_RTSPS.md`)
- **ffmpeg 구성**(`wj_device_agent/stream.py` `StreamManager.start`):
  - 입력: `-f v4l2 -input_format mjpeg -framerate {fps} -video_size {width}x{height} -i {camera_device}`(환경변수로 조정) + 선택적 오디오 입력
  - 매핑: `-map 0:v:0` 고정, 오디오는 설정에 따라 `-map 0:a:0`/`-map 1:a:0`/매핑 없음
  - 인코딩: `-c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -g {fps*2} -bf 0 -b:v {VIDEO_BITRATE 기본 2500k}`, 오디오는 `-c:a`(설정) 또는 `-an`
  - 출력: `-f rtsp -rtsp_transport tcp {publish_url}`
- **수명 관리**: `ready_delay_seconds`(기본 3초) 후 `STREAM_READY`/`STREAM_ERROR(PUBLISH_FAILED)` 발행(MQTT-04). `_monitor` 스레드가 1초마다 `hard_expires_at` 초과를 검사해 초과 시 자동 종료 + `STREAM_HARD_EXPIRED`, ffmpeg 자체 종료 시 `STREAM_ERROR(STREAM_RELAY_EXITED)` 발행. 프로세스당 스트림 1개만 유지(`DEVICE_BUSY`로 거부), `EXTEND_STREAM`은 동일 `streamId`의 `hard_expires_at`만 갱신
- 소스: `ai/device_agent/wj_device_agent/stream.py`, `ai/device_agent/wj_device_agent/configure_media.py`, `ai/device_agent/wj_device_agent/config.py`, `ai/device_agent/wj_device_agent/agent.py`

⚠️ 참고(별도/실험 단계): `ai/pi_homecam_dev/`의 라즈베리파이 프로토타입은 `/dev/video0`를 로컬 MediaMTX(`rtsp://127.0.0.1:8554/homecam`)로 단순 송출만 하며 이벤트 녹화·업로드 로직이 없다 — 초기 카메라 송출 검증용이며 운영 경로와 무관.

### 4.2 HLS 재생(앱)

- 세션 생성: 앱이 API-35(`POST /api/devices/{deviceId}/stream-sessions`) 호출 → `StreamSessionResponse.playUrl`을 서버가 내려주는 값 그대로 `VideoPlayerController.networkUrl(Uri.parse(url))`에 사용(⚠️ 실제 URL 포맷(m3u8 여부 등)은 서버 응답에 달려 있어 프런트 코드만으로는 확정 불가 — 미확인)
- 재생 URL 구성(백엔드 `StreamProperties` 근거): `{media-base-url}/{streamId}/index.m3u8?token={liveToken}` — `media-base-url` 기본값 `http://localhost:8888/live`(⚠️ docker-compose.yml의 `mediamtx` 서비스로 교차 확인, application.yml 자체엔 "MediaMTX" 이름 없음)
- 타이밍 설정(`app.stream.*`): `viewer-ttl`(45s), `idle-timeout`(60s), `edge-lease`(120s, 기기 하드 만료), `heartbeat-interval`(15s), `live-token-ttl`(30s, HLS 재생 토큰 유효기간 — `LiveTokenService`)
- 상태 폴링: 앱이 세션 생성 후 `session != null`이면 2초 간격으로 API-36(`GET /api/stream-sessions/{sessionId}`) 재조회, `READY`면 폴링 중단 후 재생, `FAILED/CLOSED/EXPIRED`면 타이머 취소 및 에러 표시
- Heartbeat: `heartbeatIntervalSeconds`(서버 값, 기본 15s) 간격으로 API-38 호출
- 재생 토큰 갱신: `READY` 진입 후 20초마다 API-36 재호출 + 플레이어 재생성 — 코드 주석: "Backend live JWT expires after 30 seconds. Recreating the network source every 20 seconds keeps Nginx playlist/segment auth valid."(재생 URL 서명이 30초 후 만료되므로 20초마다 선제 교체)
- 종료: 화면 dispose/백그라운드 전환 시 API-37(`closeStream`) 호출 및 타이머 전부 취소
- 재생 인가 확인(MediaMTX 추정, ⚠️ 미확인): API-34(`GET /api/live/introspect`)
- 소스(백엔드): `stream/api/StreamController.java`, `stream/application/StreamService.java`, `config/StreamProperties`(`app.stream.*`) / (프런트) `frontend/lib/ui/live_screen.dart`

### 4.3 MinIO 서명 URL

- **엔드포인트**(`app.storage.*` → `StorageProperties`, `config/StorageConfig.java`): `endpoint`(기본 `http://localhost:9000`), `public-endpoint`(presign URL 발급 전용, 기본은 `endpoint`와 동일 — 내부용 `minioClient`와 presign 전용 `presignClient`를 분리 생성), `access-key`/`secret-key`(기본 `minioadmin`/`minioadmin`), `bucket`(기본 `wj-videos`)
- **업로드(PUT)**: API-25 응답의 `uploadUrl` — `upload-url-ttl`(기본 15분), `x-amz-meta-sha256` 헤더 포함
- **재생/다운로드(GET)**: API-31/API-32 응답의 `url` — `read-url-ttl`(기본 5분), 다운로드(API-32)는 `response-content-disposition=attachment` 쿼리 추가
- **에러**: 스토리지 실패 시 공통 코드 503 `OBJECT_STORAGE_UNAVAILABLE`, 업로드 완료(API-26) 시 객체 미존재는 409 `UPLOAD_OBJECT_NOT_FOUND`
- 소스: `storage/ObjectStorageService.java`, `config/StorageConfig.java`(`StorageProperties`)

---

## 5. 교차 검증 요약

### 5.1 REST — baseline 49행 + 🔴 1행 = 50행

| 상태 | 개수 | 비고 |
|---|---|---|
| ✅ 사용됨 | 42 | API-01~05,07~08,10~13,14~16,18~24,25~33,35~41,42,44~45,50(도메인 순서 기준, cross-check #1~49 중 42건) |
| 🔶 서버 구현·클라이언트 미사용 | 7 | API-09(기기 단건조회), API-17(membership-request-links open), API-46(event-stats), API-47~49(provisioning 3건), API-34(live/introspect) |
| 🔴 클라이언트 호출·서버 부재 | 1 | API-06 `PATCH /api/auth/me`(baseline 49행 밖의 추가 행) |
| ⚠️ 스키마 불일치 | 0 | REST 쪽은 필드 단위 불일치 없음(요청/응답 필드가 코드 대조 결과 모두 일치) |
| **합계** | **50** | 49(✅42+🔶7) + 🔴1 |

**주요 불일치 및 영향**

1. **API-06 `PATCH /api/auth/me`** — 프런트 `SettingsScreen`의 프로필 이름 수정 기능이 서버 매핑 부재로 실패할 것으로 판단됨(`AuthController.java` 전수 확인, 저장소 전체 grep 0건). 영향: 프로필 수정 기능 미동작.
2. **API-09 `GET /api/devices/{deviceId}`** — 서버는 구현되어 있으나 앱/엣지 모두 호출하지 않음. 영향: 없음(죽은 서버 코드).
3. **API-17 `.../membership-request-links/{token}/open`** — 앱이 아니라 외부 브라우저가 여는 302 리다이렉트 전용. 영향: 없음(설계된 동작).
4. **API-46 `event-stats`** — 정교하게 구현되었으나 `LaughReportScreen`은 대신 API-33(`video-stats`)만 사용. 영향: `device_events`/이벤트 통계 API가 사실상 미사용 상태.
5. **API-47~49(provisioning)** — 내부 관리자 키 전용 운영 절차로, 코드상 호출부는 없음(사람이 직접 curl). 영향: 없음(설계된 동작).
6. **API-34(live/introspect)** — 호출 주체가 코드로 확인되지 않음(MediaMTX 추정). ⚠️ 미확인.

### 5.2 MQTT — baseline 9행(dynsec 2행 포함) + `homecam/v2` 6행 = 15행

| 상태 | 개수 | 비고 |
|---|---|---|
| ✅(일부 ⚠️ 포함, 실제 연동은 됨) | 1 | MQTT-01(`commands`) — 기기측 PING 미사용 분기 존재하나 정상 동작 |
| ⚠️ 스키마/타입 불일치 | 4 | MQTT-02(`status`, reason/occurredAt 무시), MQTT-03(`commands/ack`, errorCode 등 무시), MQTT-04(`stream/events`, STREAM_STARTING 미처리), MQTT-05(`heartbeat`, recording/uploadQueueDepth 항상 스텁값 + 잉여 필드) |
| 🔶 서버 구현·기기 미발행 | 2 | MQTT-06(`registration`, HTTP로 대체), MQTT-07(`events`, HTTP 업로드로 대체 — `device_events` 테이블 사실상 미사용) |
| 🔴 기기(AI) 발행·백엔드 미구독 | 6 | MQTT-10~15(`homecam/v2` 전부) — 실험 단계, 운영 비활성 |
| 해당없음(브로커 관리 채널) | 2 | MQTT-08, MQTT-09(`$CONTROL/dynamic-security/v1[/response]`) |

**주요 불일치 및 영향**

1. **MQTT-07(`events`, 기기 감지 이벤트)** — 백엔드는 `localClip`/`source` 스키마까지 정교하게 검증하는 핸들러를 갖췄지만 발행자가 없음. 웃음 감지→영상 저장은 API-25/26(HTTP)로만 동작하며, `device_events` 테이블(V18)·MQTT 이벤트 스키마는 as-built 기준 미사용 죽은 경로. 영향: 설계된 이벤트 기반 아키텍처 중 절반이 미가동.
2. **MQTT-06(`registration`)** — 동일하게 백엔드만 구현, 발행자 없음(등록 코드 발급은 API-43 HTTP로만 이루어짐).
3. **MQTT-04(`stream/events`)의 `STREAM_STARTING`** — 백엔드가 조용히 무시(default 분기). 영향: 스트림 시작 시점 상태 추적 공백(장애는 아님).
4. **MQTT-05(`heartbeat`)의 `recording`/`uploadQueueDepth`** — 필드명은 일치하나 기기 측이 항상 고정값(`false`/`0`)을 보내 API-11(`DeviceStatusResponse.recording/uploadQueueDepth`)에 실제 상태가 반영되지 않음. 영향: 앱 홈 화면의 녹화 상태/업로드 큐 표시가 항상 고정값일 수 있음.
5. **MQTT-10~15(`homecam/v2` 6개, YOLO/YAMNet 실험 파이프라인)** — 전부 백엔드 미구독. `control/framing/target`(MQTT-11)은 구독자(서보 제어기)조차 저장소 내에 존재하지 않아 발행만 되고 소비되는 곳이 전무함. 단, 운영 배포 스크립트에서 MQTT 자체를 비활성화해 둔 실험 단계 산출물이므로 "운영 결함"이 아니라 "구조적으로 분리된 미완성 파이프라인"으로 해석.

### 5.3 참고 — 프런트 스텁 기능 (REST/MQTT 어느 쪽 카운트에도 미포함)

다음 5개 지점(4개 기능)은 프런트 UI에는 존재하나 `api_client.dart`에 대응 호출 자체가 없고(로컬 스낵바만 표시) 백엔드에도 대응 코드가 없어, "클라이언트 호출·서버 부재"(🔴) 판정 대상에서 제외했다(호출이 없어 "행"으로 잡을 경로/메서드 자체가 없음).

| 기능 | 프런트 근거 | 백엔드 대응 |
|---|---|---|
| 기념일 저장 | `frontend/lib/ui/extra_screens.dart:193,296` | 없음(backend 전체 "anniversary" 매치 0건) |
| 비밀번호 찾기 | `frontend/lib/ui/auth_screen.dart:249-256` | 없음 |
| 비밀번호 변경 | `frontend/lib/ui/settings_screen.dart:271-274` | 없음 |
| 소셜 로그인(Apple/Google/카카오) | `frontend/lib/ui/auth_screen.dart:284-298` | 없음(OAuth2 Resource Server는 JWT 검증용, 소셜 로그인 발급용 아님) |
| 알림 읽음 처리 | `frontend/lib/ui/extra_screens.dart:46` | 없음(notification 테이블/엔드포인트 없음) |

---

## 검증

- REST 항목 수: backend 인벤토리 엔드포인트 49개 + 🔴 1개(`PATCH /api/auth/me`) = **50개**. 본 문서 API-01~API-50과 정확히 일치.
- MQTT 항목 수: cross-check 대조표 15행(`wj/v2` baseline 9행 + `homecam/v2` 6행) = **15개**. 본 문서 MQTT-01~MQTT-15와 정확히 일치.
- 도메인별 API ID 구간: auth(API-01~06, 6개) / device(API-07~13, 7개) / invitation(API-14~24, 11개) / video(API-25~33, 9개) / stream·live(API-34~38, 5개) / subscription(API-39~41, 3개) / home(API-42, 1개) / iot(API-43~46, 4개) / provisioning(API-47~49, 3개) / audit(API-50, 1개). 합계 6+7+11+9+5+3+1+4+3+1 = **50** → 검증식 성립.
