# API 명세서

> 기준: to-be 기획(MVP 2026-07-27 확정) · 코드 현황 참조 커밋 cb65eff

본 문서는 **목표(to-be) 기준**의 API 명세서다. `03-기능명세서.md`에서 정의한 **MVP 7단계**를 뼈대로, 각 단계에서 사용하는 REST API·MQTT 토픽·미디어 경로를 실제 요청/응답 스키마와 함께 배치한다.

- API/MQTT ID는 기존 as-built 문서(API-01~50, MQTT-01~15)의 번호를 그대로 재사용하고, 이후 문서화된 API-51~70에 이어 신규 API-71·72·73만 뒤에 덧붙였다. 문서 배치는 MVP 7단계 순서로 재구성했지만 기존 번호 자체는 바뀌지 않았다. **그중 API-73은 그 뒤 구현 전에 회수됐다**(6절 참고) — 번호는 비워 둔 채 재사용하지 않는다.
- 프로토콜 사실(경로·요청/응답 필드·에러 코드·MQTT 토픽·미디어 경로)은 코드에서 직접 검증된 as-built본(git 이력 `723bdbc`)에서 그대로 가져온 것이며, 이번 재작성에서 재검증하지 않았다.
- **신규 API-62**(`GET /api/devices/{deviceId}/laugh-report`)은 구현된 FN-A38 Flutter 화면의 단말 집계를 FN-S26 서버 집계로 확장하기 위한 **초안**이다. 표·본문 전체에 **[제안]** 배지를 붙여 기존 구현 API와 구분한다.
- **신규 API-71·API-72**(4컷 만화 구성·그림, FN-A40)는 앱·백엔드·만화 워커 모두 구현됐다(6절). 앱은 기본으로 실서버를 부른다 — 견본으로 돌리려면 `--dart-define=COMIC_SERVER=false`를 준다.
- **이 셋은 원래 API-52·53·54였다.** 그 번호는 금고 구독(API-51~53)·금고 접근 기록(API-54)이 이미 쓰고 있어, 리포트 제안을 API-51에서 API-62로 옮긴 것과 같은 원칙으로 API-71·72·73으로 옮겼다(12절 ID 검증 참고). 옛 문서·커밋의 "API-52~54"가 무엇을 가리키는지는 문맥으로 판단할 것.
- **자동 자막은 폰에서 만든다 — 서버를 쓰지 않는다.** 한때 앱에 담은 whisper 모델의 성능이 모자라 서버 전사(Gemini, API-73)로 옮기려 했지만, 그 사이 폰에서 도는 ML Kit 음성 인식이 같은 영상에서 whisper를 모든 축에서 앞질렀다 — 홈캠 클립에서 CER **23.3% 대 35.0%**, 2분 20초 영상을 **약 18초 대 235초**에 처리했고, whisper는 64초를 넘기면서 영어 환각까지 냈다. 그래서 whisper 모델 파일과 온디바이스 whisper 코드를 **지웠고**(커밋 `3bb0a47`), 서버 전사 엔드포인트 API-73도 만들지 않고 회수했다. 자막의 오디오와 전사문은 폰을 떠나지 않는다. 측정 기록은 `06-STT모델가이드.md`에 있다.
- MVP 7단계·가족 공유 밖의 API는 **부록 A**에 표 하나로 축약했다. 구현 상태는 본문에 넣지 않고 **부록 B**에서만 요약한다.
- as-built본의 "사용 상태(✅/🔶/🔴)" 열과 교차검증 절은 이 문서(to-be 기획서)의 성격에 맞지 않아 제거했다. 필요 시 git 이력의 as-built본을 참조한다.

---

## 1. 공통 사항

### 1.1 베이스 URL

- 프런트엔드 기본값: `https://i15e201.p.ssafy.io` (`String.fromEnvironment('API_BASE_URL', ...)`, `frontend/lib/core/api_client.dart`)
- 디바이스 에이전트가 호출하는 API 베이스 URL은 `device-agent.env`의 `API_BASE_URL`로 주입(`ai/device_agent/wj_device_agent/config.py`).

### 1.2 인증 3종

| # | 방식 | 대상 경로(matcher) | 검증 방법 | 실패 응답 | 대상 컨트롤러 |
|---|---|---|---|---|---|
| 1 | 내부 관리자 키 | `/internal/admin/**` | `ProvisioningAuthenticationFilter` — 헤더 `X-Provisioning-Key` + loopback(127.0.0.1/::1) 검사 | 키 불일치/비-loopback이면 **404 RESOURCE_NOT_FOUND**로 위장(엔드포인트 존재 자체를 숨김) | `ProvisioningController` |
| 2 | 기기 credential(Bearer) | `/api/iot/**` | `DeviceAuthenticationFilter`+`DeviceCredentialAuthenticator` — `Authorization: Bearer <keyId>.<secret>`. `/api/iot/enrollment`는 `ROLE_DEVICE_BOOTSTRAP`, 나머지는 `ROLE_DEVICE_OPERATING` | **401 DEVICE_AUTHENTICATION_FAILED** | `IotRegistrationController`, `DeviceCredentialController`, `IotVideoController` |
| 3 | 사용자 JWT | 나머지 전부 | OAuth2 Resource Server + HS256 JWT. `sub`=사용자 UUID, `sid`=세션 UUID | 미인증 **401 AUTHENTICATION_REQUIRED**, 인가 실패 **403 ACCESS_DENIED** 또는 **403 FORBIDDEN_ROLE** 등 | 그 외 전 컨트롤러 |

`permitAll`(인증 불필요): `POST /api/auth/signup`, `POST /api/auth/login`, `POST /api/auth/refresh`, `POST /api/auth/password/forgot`, `POST /api/auth/password/reset`, `GET /api/membership-request-links/*/open`, `GET /actuator/health`, `GET /api/live/introspect`.

### 1.3 공통 에러 형식

`ErrorResponse`(`code`, `message`, `requestId`, `fieldErrors`) — `fieldErrors`는 null이면 응답 본문에서 생략된다.

전역 예외(모든 엔드포인트에 잠재적으로 적용되므로 아래 단계별 표에는 반복 표기하지 않고, 엔드포인트별 비즈니스 에러 코드만 기재한다):

| 예외 | 상태코드 | 코드 |
|---|---|---|
| `ApiException` | `exception.status()` | `exception.code()`(비즈니스 에러, 아래 각 API에 개별 기재) |
| `MethodArgumentNotValidException`(Bean Validation 실패) | 422 | `VALIDATION_FAILED` |
| `HttpMessageNotReadableException`(JSON 파싱 실패) | 422 | `MALFORMED_JSON` |
| `MissingRequestHeaderException` | 422 | `MISSING_REQUIRED_HEADER` |
| 그 외 `Exception` | 500 | `INTERNAL_SERVER_ERROR` |

---

## 2. MVP ① 회원가입 / 로그인

### 사용자 흐름

1. 앱 실행 시 세션 유무를 확인해 로그인 화면 또는 메인 화면으로 분기한다.
2. 미인증 상태면 이메일/비밀번호로 로그인하거나 신규 계정을 만든다.
3. 액세스 토큰 만료 시 리프레시 토큰으로 자동 갱신한다.

### API-01 `POST /api/auth/signup`

- 인증: 공개(permitAll)

요청

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| email | String | 필수 | `@NotBlank @Email @Size≤320` |
| password | String | 필수 | `@NotBlank @Size 10~72` |
| displayName | String | 필수 | `@NotBlank @Size≤60` |
| (Header) X-Client-Name | String | 옵션 | 클라이언트 식별자(세션 표시용) |

응답: `201 AuthTokenResponse`

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

### API-02 `POST /api/auth/login`

- 인증: 공개(permitAll)

요청

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| email | String | 필수 | `@NotBlank @Email @Size≤320` |
| password | String | 필수 | `@NotBlank @Size≤72` |
| (Header) X-Client-Name | String | 옵션 | 클라이언트 식별자 |

- 응답: `200 AuthTokenResponse` (API-01과 동일 스키마)
- 에러: 401 `INVALID_CREDENTIALS`, 429 `LOGIN_RATE_LIMITED`(이메일+IP 지문 기준 5회/10분 초과)

### API-03 `POST /api/auth/refresh`

- 인증: 공개(permitAll)

요청

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| refreshToken | String | 필수 | `@NotBlank @Size 32~2048` |
| (Header) X-Client-Name | String | 옵션 | 클라이언트 식별자 |

- 응답: `200 AuthTokenResponse`
- 에러: 401 `INVALID_REFRESH_TOKEN`
- 비고: 액세스 토큰 TTL 15분, 리프레시 토큰 TTL 14일(사용할 때마다 재발급, rotate-on-use). 리프레시 토큰은 평문이 아닌 해시로 저장.

---

## 3. MVP ② 기기 등록

### 사용자 흐름

1. 젯슨이 등록 모드에 진입해 서버에서 등록 코드를 발급받아 표시한다.
2. 폰이 8자리 코드를 직접 입력해 서버에 제출(claim)한다.
3. 젯슨은 별도로 1회용 부트스트랩 자격증명을 정식 운영 자격증명으로 교환하고, 만료 전에 회전한다.
4. 등록 후 폰은 기기 목록과 상태를 조회할 수 있다.

### API-08 `POST /api/devices/claim`

- 인증: 사용자 JWT

요청

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| registrationCode | String | 필수 | `@NotBlank @Size 8~12` |
| name | String | 옵션 | `@Size 1~80`, 공백만 불가 |
| vaultId | UUID | 옵션 | 기존 추억 금고에 기기를 추가할 때 사용. 생략하면 새 금고를 생성 |
| vaultName | String | 옵션 | `@Size 1~80`, 공백만 불가. 새 금고 생성 시 금고 이름 지정 |

응답: `201 DeviceResponse`

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

- 에러: 429 `CLAIM_RATE_LIMITED`(5회/10분), 409 `DEVICE_CLAIM_REJECTED`
- 비고: claim은 물리 기기와 추억 금고 사이의 활성 Binding을 생성한다. 새 금고에는 요청 계정이 OWNER가 되며, 기존 금고에는 OWNER만 기기를 추가할 수 있다.

### Vault API `GET/POST /api/vaults`

- 인증: 사용자 JWT
- `GET /api/vaults`: 사용자가 참여 중인 추억 금고와 현재 연결 기기 목록 조회
- `GET /api/vaults/{vaultId}`: 추억 금고 단건 조회
- `POST /api/vaults`: 기기 없이도 독립적인 추억 금고 생성 — 요청 본문 `{name}`(필수, `@NotBlank @Size≤80`)

`VaultResponse` 핵심 필드:

| 필드명 | 타입 | 설명 |
|---|---|---|
| id | UUID | 추억 금고 ID |
| name | String | 사용자에게 표시할 금고 이름 |
| status | String | ACTIVE/CLOSING/CLOSED |
| myRole | String | OWNER/MEMBER |
| retentionDays | int | 금고 공통 영상 보관 기간 |
| subscriptionActive | boolean | 금고 구독 상태 |
| subscriptionGraceUntil | Instant(nullable) | 구독 해지 후 유예 만료 시각 |
| devices | List\<VaultDeviceResponse\> | 활성 Device Binding과 물리 기기 정보(`bindingId`, `generation`, `deviceId`, `name`, `model`, `status`, `lastSeenAt`). 연결 기기가 없으면 빈 배열 |

- 비고: 금고는 기기가 없어도 유지된다. 멤버십·구독·영상 접근 권한은 기기가 아니라 금고에 귀속된다.
- 앱 연동: 로그인 직후 목록을 조회해 `selectedVault`를 복원하고, 홈·가족 탭 진입과 앱 재개 시에도 재조회해 기기 온라인 상태를 갱신한다. `devices`가 비어 있어도 앱은 5탭 홈으로 진입해 `GET /api/videos?vaultId=...`로 과거 영상을 조회하고, 새 기기 연결 시 claim 요청에 이 금고의 `id`를 넣는다.

### Vault 구독 API `/api/vaults/{vaultId}/subscription`

- 인증: 사용자 JWT
- `GET`: 금고 구성원이 구독 상태 조회
- `PUT`: OWNER가 구독 활성화
- `DELETE`: OWNER가 구독 해지

응답은 기기 기준 API-39~41과 같은 `SubscriptionResponse`이며, 금고 경로로
조회하면 `deviceId`가 `null`이고 `vaultId`가 채워진다.

- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`, 409 `SUBSCRIPTION_NOT_ACTIVE`
- 비고: 구독은 금고에 귀속되므로 연결된 기기가 한 대도 없어도 조회·변경할 수
  있다. 기기 기준 API-39~41은 호환을 위해 유지하며 같은 금고 행을 갱신한다.

### Vault 접근 기록 API `GET /api/vaults/{vaultId}/access-logs`

- 인증: 사용자 JWT, 금고 OWNER만 허용
- 요청: `cursor`(선택), `size`(기본 20, 1~100)
- 응답: API-50과 같은 커서 페이지
- 비고: V30 이전에 기록되어 `vault_id`가 비어 있는 행은 그 금고에 Binding된
  적이 있는 기기의 `device_id`로도 함께 조회한다.

### API-43 `POST /api/iot/registration-codes`

- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING)
- 요청: `@AuthenticationPrincipal DevicePrincipal`(본문 없음)

응답: `200 RegistrationCodeResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| registrationCode | String | 필수 | 화면 표시용 등록 코드 |
| expiresAt | Instant | 필수 | 만료 시각(TTL 120초) |

- 에러: 409 `DEVICE_ALREADY_CLAIMED`
- 비고: 코드는 해시로만 저장(평문 미보관). 코드 중복 시 최대 5회 재생성.

### API-44 `POST /api/iot/enrollment`

- 인증: 기기 credential(Bearer, ROLE_DEVICE_BOOTSTRAP)
- 요청: `@AuthenticationPrincipal DevicePrincipal`(본문 없음)

응답: `200 ProvisionedDeviceResponse`

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
- 비고: 1회용 BOOTSTRAP(TTL 15분) 토큰을 OPERATING(TTL 30일) 자격증명으로 교환한다.

### API-45 `POST /api/iot/credentials/rotate`

- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING)
- 요청: `@AuthenticationPrincipal DevicePrincipal`(본문 없음)
- 응답: `200 ProvisionedDeviceResponse` (API-44와 동일 스키마)
- 에러: 404 `RESOURCE_NOT_FOUND`, 401 `DEVICE_CREDENTIAL_STALE`, 403 `DEVICE_CREDENTIAL_PURPOSE_INVALID`
- 비고: 기기당 활성(ACTIVE) 자격증명은 1개만 유지되며, 만료 전 회전한다.

### API-07 `GET /api/devices`

- 인증: 사용자 JWT
- 요청: 없음

응답: `200 List<DeviceSummaryResponse>`

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
- 비고: 호출자의 활성 멤버십 기준으로 접근 가능한 기기만 필터링된다.

### API-11 `GET /api/devices/{deviceId}/status`

- 인증: 사용자 JWT
- 요청: PathVariable `deviceId`

응답: `200 DeviceStatusResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| deviceId | UUID | 필수 | 기기 ID |
| status | String | 필수 | 상태 |
| recording | boolean | 필수 | 최근 MQTT heartbeat가 보고한 녹화 중 여부 |
| uploadQueueDepth | int | 필수 | 최근 MQTT heartbeat가 보고한 업로드 대기열 깊이 |
| bufferSeconds | Integer | 옵션(nullable) | 버퍼 초 |
| personCount | Integer | 옵션(nullable) | 인원 수 |
| checkedAt | Instant | 필수 | 조회 시각 |

- 에러: 404 `RESOURCE_NOT_FOUND`

---

## 4. MVP ③ 홈에서 라이브 스트리밍 시청

### 사용자 흐름

1. 홈 화면의 라이브 카드를 탭하면 재생이 시작된다(진입 시 자동 재생은 없다).
2. 연결된 뒤 컨트롤바의 전체화면 버튼으로 전체화면에 진입한다.
3. 화면을 벗어나거나 세션이 만료되면 시청이 자동으로 종료된다.

### API-35 `POST /api/devices/{deviceId}/stream-sessions`

- 인증: 사용자 JWT
- 요청: PathVariable `deviceId`

응답: `202 Accepted StreamSessionResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| sessionId | UUID | 필수 | 세션 ID |
| streamId | UUID | 필수 | 스트림 ID |
| deviceId | UUID | 필수 | 기기 ID |
| status | String | 필수 | PENDING/READY/FAILED/CLOSED/EXPIRED |
| whepUrl | String | 옵션(nullable) | 운영 WebRTC/WHEP 전용 재생 URL(`READY` 상태에서 값 존재) |
| heartbeatIntervalSeconds | int | 필수 | 하트비트 주기(초, 기본 15초) |
| viewerExpiresAt | Instant | 필수 | 뷰어 세션 만료 시각(TTL 45초) |
| edgeHardExpiresAt | Instant | 필수 | 기기측 하드 만료 시각(TTL 120초) |
| failureCode | String | 옵션(nullable) | 실패 코드 |
| createdAt | Instant | 필수 | 생성 시각 |

- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `DEVICE_OFFLINE`(기기 오프라인이면 세션 생성 거부)

### API-36 `GET /api/stream-sessions/{sessionId}`

- 인증: 사용자 JWT
- 요청: PathVariable `sessionId`
- 응답: `200 StreamSessionResponse` (API-35와 동일 스키마)
- 에러: 404 `RESOURCE_NOT_FOUND`
- 비고: 앱은 세션 생성 후 2초 간격으로 상태를 폴링해 `READY`가 되면 재생을 시작한다.

### API-37 `DELETE /api/stream-sessions/{sessionId}`

- 인증: 사용자 JWT
- 요청: PathVariable `sessionId`
- 응답: `204 No Content`
- 에러: 404 `RESOURCE_NOT_FOUND`

### API-38 `POST /api/stream-sessions/{sessionId}/heartbeat`

- 인증: 사용자 JWT
- 요청: PathVariable `sessionId`
- 응답: `204 No Content`
- 에러: 404 `RESOURCE_NOT_FOUND`
- 비고: `heartbeatIntervalSeconds`(기본 15초) 간격으로 호출해 뷰어 세션 유휴 타임아웃(60초)을 방지한다.

### MQTT-01 `{base}/devices/{deviceId}/commands`

- 방향: 발행(백엔드→기기)
- 페이로드: `{schemaVersion:"2.0", requestId, deviceId, type: START_STREAM|EXTEND_STREAM|STOP_STREAM, issuedAt, expiresAt(issuedAt+15s), payload}`
  - `START_STREAM.payload = {sessionId, streamId, profile:"LIVE_720P_H264_OPUS", hardExpiresAt}`
  - `EXTEND_STREAM.payload = {streamId, hardExpiresAt}`
  - `STOP_STREAM.payload = {streamId, reason}`
- 트리거: 백엔드가 스트림 세션 생성/연장/종료 시 발행
- QoS 1(retained=false)

### MQTT-04 `{base}/devices/+/stream/events`

- 방향: 구독(기기→백엔드)
- 백엔드 스키마: `{schemaVersion, deviceId, streamId, type: STREAM_READY|STREAM_ERROR|STREAM_HARD_EXPIRED|STREAM_STOPPED, hardExpiresAt?, errorCode?}`
- 트리거: 스트림 상태 전이 시(준비완료/오류/하드만료/중지)
- QoS 1

### 미디어 경로

#### RTSPS publish (Jetson → MediaMTX)

- **송출 트리거**: 기기가 MQTT-01로 `START_STREAM`을 수신하면 `StreamManager.start(stream_id, hard_expires_at)` 실행
- **송출 URL**: `rtsps://{username}:{password}@{host}:8322/live/{stream_id}` — 자격증명 포함, 경로 `/live/{stream_id}` 고정, 쿼리/프래그먼트 금지, TLS CA 인증서 필수
- **ffmpeg 구성**: 로컬 공유 스트림의 H.264 영상은 `-c:v copy`로 전달하고, AAC 원본 오디오는 WebRTC 호환 Opus 48kHz 모노·64kbps(`-c:a libopus -application lowdelay`)로 변환한 뒤 `-f rtsp -rtsp_transport tcp {publish_url}`로 출력한다. 이 변환은 앱 Live View 릴레이에만 적용되며 로컬 `/homecam/main`, `/homecam/ai`와 녹화의 AAC 오디오는 유지한다.
- **수명 관리**: 준비 지연(기본 3초) 후 `STREAM_READY`/`STREAM_ERROR` 발행(MQTT-04). 1초 주기로 하드 만료(`hard_expires_at`) 검사 후 초과 시 자동 종료(`STREAM_HARD_EXPIRED`). 기기당 스트림 1개만 유지(`DEVICE_BUSY`로 거부). `EXTEND_STREAM`은 동일 `streamId`의 하드 만료 시각만 갱신

#### WebRTC/WHEP 전용 재생(앱)

- 세션이 `READY`가 되면 앱은 `StreamSessionResponse.whepUrl`을 먼저 사용한다.
- WHEP 연결: 앱이 영상과 오디오를 모두 포함한 recv-only SDP offer를 `POST application/sdp`로 보내고 MediaMTX의 SDP answer를 적용한다. 수신된 원격 오디오 트랙은 영상과 같은 `RTCVideoRenderer`에 연결하며 음소거 버튼으로 볼륨을 제어한다. 별도 WebSocket 시그널링 서버는 없다.
- 운영 API는 `playUrl`을 반환하지 않으며 앱에는 HLS 재생 경로가 없다. `whepUrl`이 없거나 WHEP/ICE 연결이 실패하거나 SDP answer의 영상이 원격 송신 방향(`sendonly`/`sendrecv`)이 아니면 연결 실패를 표시하고 사용자가 재시도할 수 있게 한다.
- 연결 성공은 원격 video track 수신이 확인된 시점이다. 오디오 트랙 또는 inbound audio RTP가 없거나 늦어도 영상 재생은 유지하고 `영상만 연결됨`을 표시하며, 패킷이 뒤늦게 도착하면 음량 제어를 자동 활성화한다.
- 정상 송출 오디오는 WebRTC 호환 Opus를 사용한다. AAC-only 송출은 MediaMTX가 WebRTC 오디오 트랙을 건너뛸 수 있으므로 앱이 영상 전용으로 강등해 재생한다.
- URL 구성: WHEP `{webrtc-base-url}/{streamId}/whep?token={liveToken}` — 운영 재생 URL은 이것뿐이다.
- 타이밍: 뷰어 TTL 45초, 유휴 타임아웃 60초, 기기측 하드 만료(edge-lease) 120초, 하트비트 주기 15초, 라이브 토큰 TTL 30초
- 상태 폴링: 세션 생성 후 2초 간격으로 API-36 재조회, `READY`면 재생 시작, `FAILED/CLOSED/EXPIRED`면 에러 표시
- 종료: 화면 이탈 시 WHEP 세션 `Location`에 `DELETE`한 뒤 API-37 호출
- 재생 인가 확인: **API-34** `GET /api/live/introspect`(공개, `token`/`streamId` 서명 검증 → `204`/`401`) — Nginx가 WHEP 접근 시 호출하는 내부 인가 확인 경로로, 앱/젯슨이 직접 호출하지 않는다.
- 운영 경로: HTTPS 443의 Nginx `/webrtc/.../whep` → host loopback MediaMTX 8889, WebRTC 미디어/ICE는 UDP 8189. 8889는 외부에 직접 공개하지 않는다.

---

## 5. MVP ④ 이벤트(웃음) 감지 영상 확인

### 사용자 흐름

1. 젯슨이 오디오를 분석해 웃음소리를 감지하면 전후 구간을 클립으로 만들어 서버 업로드 흐름(presigned URL)으로 자동 업로드한다.
2. 사용자는 캘린더 또는 영상 목록에서 날짜별로 저장된 클립을 확인한다.
3. 상세 화면에서 클립을 재생한다.

### 이벤트 업로드 흐름 (젯슨 → 서버)

1. 젯슨(YAMNet)이 웃음 트리거를 감지하면 전후 구간 클립을 로컬에 생성한다.
2. **API-25**로 업로드 URL을 발급받는다(`Idempotency-Key` = `sourceEventId`).
3. 발급받은 presigned URL로 MinIO에 `PUT` 업로드한다(TTL 15분, 500MiB 초과 거부).
4. **API-26**으로 업로드 완료를 통보하면 영상 상태가 `READY`로 전환된다.
5. 앱은 API-27(목록)·API-31(재생)로 클립을 확인한다.

### API-25 `POST /api/iot/videos/upload-url`

- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING)
- 요청: Header `Idempotency-Key`(필수, `sourceEventId`와 동일해야 함) + Body

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| sourceEventId | String | 필수 | `@NotBlank @Size≤100`, UUID 형식 |
| triggerType | String | 필수 | `@Pattern "LAUGHTER\|CLAP\|WAKE_WORD\|TOUCH\|MANUAL"` |
| eventTypes | List\<String\> | 옵션 | 함께 기록할 유형 1~3개. 생략하면 triggerType만 저장하며 triggerType을 포함해야 함 |
| title | String | 필수 | `@NotBlank @Size≤120` |
| capturedStartAt | Instant | 필수 | `@NotNull` |
| capturedEndAt | Instant | 필수 | `@NotNull` |
| durationMs | long | 필수 | `@Min 1` |
| contentType | String | 필수 | `@Pattern "video/mp4"` |
| sizeBytes | long | 필수 | `@Min 1`, 최대 500MiB |
| checksumSha256 | String | 필수 | `@Pattern [0-9a-f]{64}` |

응답: `200 IotUploadUrlResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| videoId | UUID | 필수 | 비디오 ID |
| alreadyCompleted | boolean | 필수 | 이미 업로드 완료된 idempotent 요청 여부 |
| uploadUrl | String | 옵션(nullable) | MinIO presigned PUT URL |
| method | String | 옵션(nullable) | `"PUT"` |
| requiredHeaders | Map<String,String> | 옵션(nullable) | 업로드 시 필요한 헤더(`x-amz-meta-sha256` 등) |
| expiresAt | Instant | 옵션(nullable) | URL 만료 시각(TTL 15분) |

- 에러: 413 `VIDEO_TOO_LARGE`(500MiB 초과), 422 `VALIDATION_FAILED`, 409 `DEVICE_NOT_CLAIMED`, 409 `DEVICE_VAULT_BINDING_MISSING`(기기는 등록 상태지만 활성 추억 금고 바인딩이 없음), 409 `VIDEO_STATE_CONFLICT`, 409 `IDEMPOTENCY_KEY_MISMATCH`, 409 `IDEMPOTENCY_CONFLICT`, 503 `OBJECT_STORAGE_UNAVAILABLE`
- Vault 전환 복구: `V31__repair_missing_initial_vault_bindings.sql`은 바인딩 이력이 전혀 없는 활성 레거시 기기에 한해 초기 Vault·OWNER·ACTIVE 바인딩을 복구한다. 이전 바인딩 이력이 있는 기기는 잘못된 가정으로 다른 가족 Vault에 연결하지 않도록 자동 복구하지 않으며 재등록이 필요하다.

### API-26 `POST /api/iot/videos/complete`

- 인증: 기기 credential(Bearer, ROLE_DEVICE_OPERATING)
- 요청: Header `Idempotency-Key`(필수) + Body

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| videoId | UUID | 필수 | `@NotNull` |
| objectETag | String | 옵션 | `@Size≤200` — MinIO PUT 응답의 ETag. **보내면 서버가 검증한다** |

- 응답: `200 VideoResponse` (API-27 목록의 개별 항목과 동일 스키마, 아래 참고)
- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `VIDEO_STATE_CONFLICT`(Vault 기반 READY 전환 실패 포함), 409 `IDEMPOTENCY_KEY_MISMATCH`, 409 `UPLOAD_INTEGRITY_MISMATCH`, 503 `OBJECT_STORAGE_UNAVAILABLE`
- **무결성 검증 3단**: ① 객체 크기 = 예약 시 선언한 `sizeBytes`, ② `x-amz-meta-sha256`(서명된 헤더) = 예약 시 선언한 체크섬, ③ **MinIO가 계산한 ETag = 기기가 보고한 `objectETag`**. ①②는 기기 자가 신고값이라 서명 URL이 유출됐을 때 같은 크기·같은 메타로 내용만 바꿔치는 것을 막지 못한다 — ③이 그 치환을 잡는다(ETag는 실제 바이트에서 나온다). ETag를 보내지 않는 옛 에이전트는 ③을 건너뛴다.
- 업로드 본문 상한은 서버 선언 **500 MiB**(`IotVideoService.MAX_UPLOAD_BYTES`)이며 nginx의 `/william-james-videos` 본문 한도(512m)와 같은 기준으로 맞춰 둔다 — 한쪽만 크면 초과 본문이 MinIO 디스크에 도달한 뒤에야 거절된다.

### API-27 `GET /api/videos`

- 인증: 사용자 JWT
- 요청: RequestParam

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| deviceId | UUID | 옵션 | 기기 ID — `vaultId`와 둘 중 정확히 하나만 전달 |
| vaultId | UUID | 옵션 | 금고 ID — 기기 연결 여부와 무관하게 금고 전체 영상 조회 |
| triggerType | String | 옵션 | 트리거 타입 필터 |
| from | Instant | 옵션 | 조회 시작 |
| to | Instant | 옵션 | 조회 종료 |
| cursor | String | 옵션 | 페이지 커서 |
| size | int | 옵션(기본 20) | 1~100 |

응답: `200 VideoPageResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| items | List\<VideoResponse\> | 필수 | 영상 목록(아래 `VideoResponse` 스키마) |
| nextCursor | String | 옵션(nullable) | 다음 페이지 커서 |
| hasNext | boolean | 필수 | 다음 페이지 존재 여부 |

`VideoResponse` 스키마(API-26/27/28 공통):

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| id | UUID | 필수 | 비디오 ID |
| deviceId | UUID | 필수 | 기기 ID |
| sourceType | String | 필수 | IOT_CAPTURE/USER_UPLOAD/EDIT_OUTPUT |
| triggerType | String | 필수 | LAUGHTER/CLAP/WAKE_WORD/TOUCH/MANUAL/USER_UPLOAD/EDIT |
| eventTypes | List\<String\> | 필수 | 영상에 함께 기록된 유형. triggerType을 포함하며 중복 없음 |
| sourceEventId | String | 옵션(nullable) | 원본 이벤트 ID |
| title | String | 필수 | 제목 |
| contentType | String | 필수 | 콘텐츠 타입 |
| sizeBytes | Long | 옵션(nullable) | 파일 크기 |
| checksumSha256 | String | 옵션(nullable) | 체크섬 |
| durationMs | Long | 옵션(nullable) | 길이(ms) |
| capturedStartAt | Instant | 옵션(nullable) | 촬영 시작 |
| capturedEndAt | Instant | 옵션(nullable) | 촬영 종료 |
| status | String | 필수 | UPLOADING/PROCESSING/READY/FAILED/DELETING/DELETED |
| isFavorite | boolean | 필수 | 즐겨찾기 여부 |
| thumbnailUrl | String | 옵션(nullable) | 썸네일 URL |
| createdAt | Instant | 필수 | 생성 시각 |

- `deviceId`와 `vaultId` 중 정확히 하나만 전달한다.
- 에러: 422 `VALIDATION_FAILED`(조회 기준 중복/누락, size 범위/triggerType 미지원/from≥to), 404 `RESOURCE_NOT_FOUND`, 422 `INVALID_CURSOR`

### API-31 `POST /api/videos/{videoId}/play-url`

- 인증: 사용자 JWT
- 요청: PathVariable `videoId`

응답: `200 SignedUrlResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| url | String | 필수 | MinIO presigned GET URL(재생용, TTL 5분) |
| expiresAt | Instant | 필수 | 만료 시각 |

- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `VIDEO_NOT_READY`(영상 상태가 READY가 아니면 발급 거부), 503 `OBJECT_STORAGE_UNAVAILABLE`

### MinIO 서명 URL 공통 사항

- 업로드(PUT, API-25): TTL 15분, `x-amz-meta-sha256` 헤더 포함
- 재생/다운로드(GET, API-31/API-32): TTL 5분, 다운로드는 `response-content-disposition=attachment` 쿼리 추가
- 스토리지 실패 시 503 `OBJECT_STORAGE_UNAVAILABLE`, 업로드 완료(API-26) 시 객체 미존재는 409 `UPLOAD_OBJECT_NOT_FOUND`

---

## 6. MVP ⑤ 영상 편집

### 사용자 흐름

1. 영상 상세 화면에서 편집을 시작하면 원본을 임시로 내려받는다(API-32 재사용).
2. 자막 탭을 열면 앱이 **폰 안에서** 자막을 만든다. 마이크 권한을 그 자리에서 묻고(파일로 자막을 만드는데도 ML Kit이 요구한다), 영상에서 오디오를 뽑아 ML Kit 음성 인식에 넘긴다. 2분 영상이 약 18초다. 서버에 아무것도 보내지 않고 아무것도 받아 오지 않는다. 결과는 영상 번호로 기기에 캐시해 다시 열 때 재사용한다.
3. 앱 자체 편집 화면에서 자르기·화면 비율·음량·필터·이모지 스티커 수동 편집을 진행하고, 만들어진 자동 자막을 줄마다 고친다.
4. 편집 결과는 폰에 로컬로 저장된다.
5. 같은 화면의 [4컷 만화 만들기]로 들어가면, 자막이 만든 전사문을 서버에 보내 4컷 구성을 받고(API-71) 대사를 고친 뒤 만화 그림을 받는다(API-72).

**서버 API가 필요 없는 것은 수동 편집(FN-A21)과 자동 자막(FN-A39) 둘이다** — 둘 다 폰에서 끝난다. 원본 다운로드는 ⑥ 단계와 동일한 API-32(다운로드 URL)를 재사용한다. **서버 AI를 쓰는 것은 4컷 만화(FN-A40)뿐이다** — 아래 API-71·API-72다. 폰이 올리는 것은 그 두 곳의 전사문(글)뿐이고 영상·오디오는 어느 기능도 올리지 않는다. 단 **API-71에서는 서버가 자기 저장소에 있는 원본에서 프레임 몇 장을 뽑아 Gemini(구글)로 보낸다** — 이는 개인정보 고지 대상이다.

### 4컷 만화 API 공통

> **앱·서버·만화 워커 모두 구현됐다.** 서버는 두 겹이다 — 백엔드(Spring)가 로그인·금고 권한·원본 주소 발급·호출 횟수 제한을 맡고, 그 뒤의 만화 워커(파이썬)가 생성형 모델을 부른다. 모델 키는 워커만 들고 있다.

- 앱은 인자 없이 빌드하면 실제 서버를 쓴다. `--dart-define=COMIC_SERVER=false`를 주면 가짜 응답(고정 대사와 색 블록 그림)으로 동작하며 화면에 견본이라는 알림을 띄운다 — 서버 없이 흐름만 걸어 볼 때 쓴다. 기본을 실서버로 둔 이유는, 인자를 잊으면 오류가 아니라 가짜 만화가 그대로 출고되기 때문이다.
- 백엔드는 사용자의 로그인 토큰을 워커에 그대로 넘긴다. 워커도 스스로 토큰과 금고 권한을 다시 확인하므로, 서버를 우회해 워커에 직접 들어와도 남의 영상으로는 만화를 만들 수 없다.
- 누가 어느 영상으로 만화를 만들었는지 접근 기록(API-54)에 남는다.
- **폰이 올리는 것은 전사문(글)뿐이다.** 영상·오디오·프레임은 기기를 떠나지 않는다(REQ-F-27). 미디어를 요구하는 파라미터를 추가하지 않는다 — 프레임은 **서버가 자기 저장소의 원본에서 직접 뽑는다**(API-71).
- **이미지 생성 API 키는 서버만 들고 있다.** 앱에 넣으면 APK를 뜯어 가져갈 수 있으므로, 응답에도 키를 담지 않는다.
- **에러 메시지는 사용자에게 그대로 보인다.** 앱은 응답 본문의 `message`를 꺼내 만화 화면에 그대로 띄운다. 영문 오류, 스택, 모델 이름이 아니라 한국어 사용자 문구로 쓴다.
- 공통 에러: 401 `AUTHENTICATION_REQUIRED`, 403 `ACCESS_DENIED`, 404 `RESOURCE_NOT_FOUND`(영상 없음/권한 없음), 409 `VIDEO_NOT_READY`(영상이 아직 준비 중), 422 `VALIDATION_FAILED`, 422 `COMIC_UNPROCESSABLE`(그 영상에서 만화 재료를 못 뽑았다 — 다시 눌러도 같으므로 다른 영상을 권한다), 429 `COMIC_RATE_LIMITED`(호출 횟수 제한), 502 `COMIC_WORKER_FAILED`, 503 `COMIC_WORKER_UNAVAILABLE`(만화 서버가 꺼져 있다), 504 `COMIC_WORKER_TIMEOUT`(만화 서버가 답을 안 준다), 500 `INTERNAL_SERVER_ERROR`.
- 만화 서버가 꺼진 것과 오래 걸리는 것을 구분해서 알린다. 같은 문구로 뭉개면 사용자가 영원히 다시 누른다.
- 화풍은 정해진 목록에서만 고른다(`webtoon`·`watercolor`·`crayon`). 아무 문장이나 받으면 그 문장이 그림 지시에 그대로 섞여 들어간다.
- **이 절이 어디까지 적용되는지.** 이 절의 규칙은 **만화(API-71·API-72)에만 해당한다.** 자동 자막(FN-A39)은 서버 API를 쓰지 않으므로 여기 적용될 것이 없다 — 옛 API-73 계약과 `TRANSCRIPT_` 에러 코드는 함께 회수됐다(아래 API-73 참고).
- **호출 횟수 제한은 서버만 걸 수 있다.** 이미지 생성은 호출마다 비용이 들지만 앱에는 제한이 없다.
- 제한은 사용자별·영상별로 기본 1시간 20회다. **형식이 잘못된 요청은 이 상한을 깎지 않는다** — 자기 실수로 만화를 못 만들게 되면 안 된다.
- **시간 예산은 안쪽부터 짧다: 만화 워커 150초 → 백엔드 160초 → 앱 180초.** 앱의 일반 요청은 20초를 기다리면 끊지만, 서버 AI를 쓰는 두 호출(API-71·API-72)만 180초로 따로 늘려 두었다 — 구성 생성도 그림 생성도 20초 안에 끝나는 일이 아니다. 안쪽이 먼저 끊어야 워커가 알려 주는 실패 사유가 사용자에게 전달된다. 앱이 먼저 끊으면 사용자에게는 그냥 실패로 보이고, 서버는 다 만들어 놓은 결과를 버리게 된다. 180초로도 모자란 작업이라면 "요청을 접수하고 나중에 결과를 물어보는" 방식으로 계약을 바꿔야 하는데, 그것은 이 문서의 범위 밖이다.

### API-71 `POST /api/videos/{videoId}/comic/script`

> 전사문과 **서버가 영상에서 뽑은 프레임 몇 장**을 함께 보고 4컷 구성(어떤 대사를 어느 컷에, 각 컷의 장면 묘사)을 만들어 준다. 그림보다 먼저 부르고, 사용자가 대사를 고친 뒤에 API-72으로 그림을 만든다 — 이미지 생성비를 엉뚱한 구성에 쓰지 않으려고 두 단계로 나눴다.

- 인증: 사용자 JWT **[제안]**
- 요청: PathVariable `videoId` + 본문 — **앱이 보내는 모양은 바뀌지 않았다.**

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| lines | List | 필수 | 전사문 줄 목록. 비어 있으면 422 |
| lines[].startMs | int | 필수 | 줄이 시작한 시각(ms) |
| lines[].text | String | 필수 | 들린 말. 앱이 빈 줄은 걸러서 보낸다 |

- 끝 시각(`endMs`)은 보내지 않는다 — 구성에 쓰이지 않는다.
- 줄 목록은 폰의 ML Kit이 만든 자막이다. **말이 없는 영상이면 빈 배열로 올 수 있다** — 그때는 프레임만 보고 구성해야 한다.
- **줄 개수 상한은 서버가 정해야 한다.** 앱은 기기에 캐시된 자막을 자르지 않고 그대로 보내며, 줄 수는 영상 길이에 비례한다(실측: 2분 영상에 143자, 10~20줄). 상한을 넘겼을 때 거절할지 앞부분만 쓸지도 서버가 정해 이 문서에 적어야 한다. **지금은 정해진 값이 없다.**

#### 서버가 하는 일 — 프레임을 뽑아 `gemini-3.5-flash`에 함께 넣는다

전사문만 넘기면 모델은 누가 몇 명 있고 무엇을 입었는지 알 수 없다. 그러면 컷마다 다른 사람이 그려진다. 그래서 서버가 영상을 직접 들여다본다.

1. **저장된 원본에서 프레임 4~6장을 뽑는다.** 영상 전체에 고르게 흩뿌리고, 편집 추천 서비스의 점수 타임라인(`scoreTimeline`)을 쓸 수 있으면 **점수가 높은 순간을 골라** 뽑는다.
2. **`gemini-3.5-flash`에 프레임과 줄 목록을 함께 넣는다.**
3. **프레임 수를 4~6장으로 묶어 둔 이유는 비용이다.** 2026-08-03 GMS 실측으로 작은 PNG 한 장이 **크기와 상관없이 입력 토큰 1,089개**를 먹었다. 프레임 한 장에 약 1.1k 토큰을 잡아야 하고, 이 모델은 생각하는 데 쓴 토큰(`thoughtsTokenCount`)도 따로 청구한다. 장수를 늘리면 비용이 그만큼 곧게 올라간다.

응답: `200` — 4컷 구성(**앱에 내려가는 부분**)

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| cuts | List | 필수 | **정확히 4개.** 다른 개수면 앱이 오류로 처리한다 |
| cuts[].beat | String | 필수 | 기·승·전·결 중 어디인지. 빈 문자열 불가 |
| cuts[].scene | String | 필수 | 장면 묘사(이미지 프롬프트에 들어가고 사용자에게도 보인다). 빈 문자열 불가 |
| cuts[].dialogue | String | 옵션(nullable) | 그 컷의 대사. 대사 없이 상황만 있는 컷은 null. 빈 문자열은 앱이 null로 본다 |

- 컷이 4개여야 하는 이유는 그림이 2x2 격자 한 장이고 앱이 각 칸에 자막을 얹기 때문이다. 개수가 다르면 얹을 칸이 맞지 않는다.
- **장면 묘사에 소리를 언급하지 않는다.** "큰 소리가 났다"고 쓰면 이미지 모델이 의성어를 그린다(시험에서 확인). "물건이 바닥에 흩어져 있다"처럼 눈에 보이는 것만 쓴다.
- 에러: 공통 + 422 `VALIDATION_FAILED`(`lines` 누락/빈 배열/상한 초과). 전사문이 없는 영상은 앱이 먼저 안내 화면을 띄우고 요청하지 않지만, 서버도 방어적으로 거절한다.

#### 모델은 인물표와 배경표도 함께 낸다 — 서버 안에만 둔다

1단계 모델은 네 컷 외에 **인물표(`characters`)와 배경표(`setting`)**도 낸다. 이 둘은 **앱으로 내려보내지 않는다.** API-72에서 그림 프롬프트를 짤 때 쓰는 재료다.

```json
{
  "characters": [
    {"label": "아빠", "appearance": "30대 남성, 짧은 검은 머리, 검은 뿔테 안경, 회색 후드티"}
  ],
  "setting": "밝은 낮의 거실, 베이지색 소파와 원목 탁자, 창으로 햇빛",
  "cuts": [ {"beat": "빌드업", "scene": "...", "dialogue": "그거 만지지 마"} ]
}
```

- **앱과의 계약은 그대로다.** 앱이 받는 것은 `cuts`(beat/scene/dialogue) 뿐이다. 인물표·배경표를 응답에 섞어 넣어도 앱은 무시하지만, 계약을 흐리지 않게 빼는 쪽을 권한다.
- 서버는 인물표와 배경표를 **영상 번호로 캐시**해 두고 API-72에서 꺼내 쓴다.
- **그림을 만들 때 캐시가 없으면 표 없이 조립한다.** 인물이 컷마다 조금씩 달라져 품질은 떨어지지만, **그렇다고 실패시켜서는 안 된다.**

**1단계 프롬프트에서 서버가 반드시 강제할 것**

1. 인물표에는 **프레임에 실제로 보이는 사람만** 넣는다. 전사문만 보고 없는 사람을 짐작해 넣지 않는다.
2. 겉모습은 **글만 보고 그릴 수 있을 만큼 구체적으로** 쓴다 — 연령대, 머리, 안경 유무, 옷 색과 종류. 다만 **실존 인물을 특정할 만한 정보는 넣지 않는다**(이름, 얼굴의 개별 특징, 알아볼 수 있는 로고 같은 것).
3. 장면 묘사는 **멈춘 한 순간**이어야 하고, 사람은 **인물표의 이름표로만** 가리킨다("아빠가 …"). 여기서 겉모습을 새로 덧붙이면 칸마다 인물이 달라진다.
4. 장면 묘사는 **소리를 절대 언급하지 않는다** — 소리를 쓰면 의성어가 그림에 박힌다.
5. 대사는 줄 목록에서 **글자 그대로** 가져온다. 대사 없는 컷은 `null`.
6. 컷은 **정확히 4개**여야 한다.

### API-72 `POST /api/videos/{videoId}/comic/image`

> 사용자가 고친 4컷 구성으로 만화 그림 한 장을 만들어 준다. **그림에는 글자도 말풍선도 없어야 한다** — 대사는 앱이 그림 위에 영화 자막처럼 직접 얹는다.

- 인증: 사용자 JWT **[제안]**
- 요청: PathVariable `videoId` + 본문

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| cuts | List | 필수 | API-71 응답과 같은 4개. `dialogue`만 사용자가 고쳐서 온다. 4개가 아니면 422 |
| style | String | 필수 | 화풍. **앱은 항상 `webtoon`을 보낸다**(고르는 화면이 없다). `watercolor`·`crayon`은 예정된 값이며, 모르는 값은 422 |

응답: `200`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| image | String | 필수 | 만화 그림 한 장의 **표준 base64 문자열** |

- **`image`는 접두어 없는 순수 base64여야 한다.** 앱이 받은 문자열을 그대로 복호화하므로, `data:image/png;base64,` 같은 데이터 URI 접두어, URL 안전용 알파벳(`-`·`_`), 중간에 들어간 줄바꿈·공백은 모두 실행 중 오류가 된다. 표준 알파벳(`+`·`/`)에 패딩을 붙이고 개행은 넣지 않는다.
- **PNG · 정사각형 · 2x2 격자 한 장.** 앱은 그림을 정사각형 틀에 넣고 네 사분면 아래쪽에 자막을 얹는다. 정사각형이 아니면 위아래(또는 좌우)에 빈 띠가 생겨 **자막 네 개가 모두 그림 밖에 앉는다.** 격자가 2x2가 아니면 대사가 엉뚱한 칸에 붙는다. 읽는 순서는 왼쪽 위 → 오른쪽 위 → 왼쪽 아래 → 오른쪽 아래다.
- 크기: base64는 원본보다 약 1.33배 커지고 그대로 응답 본문에 담긴다. 512~1024px 정사각형을 권한다(1024px PNG 1~2MB → base64 1.4~2.7MB). 만화를 서버에 보관하지 않기 때문에 매번 본문으로 내려온다 — "내가 만든 만화 목록"이 필요해지면 그때 스토리지 저장으로 바꾼다.
- 에러: 공통 + 422 `VALIDATION_FAILED`(컷이 4개가 아님/화풍 미지원).

#### 이미지 프롬프트를 어떤 순서로 짜는가

**앱에서는 강제할 방법이 없다** — 요청 본문에 담을 자리가 없으므로 이 문서와 서버 구현이 유일한 강제 지점이다. 아래는 PC 시험으로 다듬은 항목이다.

서버는 `gemini-2.5-flash-image`에 보낼 프롬프트 **하나**를 아래 **순서 그대로** 짠다. **순서가 결과를 바꾼다 — 앞에 놓인 지시가 더 세게 붙는다.**

1. **화풍과 판형** — 정사각형 이미지 **한 장**, 4컷 웹툰, **2x2 격자**, 컷 사이는 얇은 여백, 읽는 순서는 왼쪽 위 → 오른쪽 위 → 왼쪽 아래 → 오른쪽 아래.
2. **인물표** — API-71이 캐시해 둔 인물 문장을 **글자 하나 바꾸지 않고** 넣고, "**모든 칸에서 똑같은 사람으로 그려라**"를 못 박는다.
3. **배경** — 배경표를 넣고 **네 칸 모두**에 적용한다고 밝힌다.
4. **컷 1~4의 장면 묘사** — 사람은 **인물표의 이름표로만** 가리킨다.
5. **금지 규칙** — 아래 목록.

**⑤ 금지 규칙**

- **순수 일러스트만. 어떤 종류의 글씨도 넣지 않는다** — 글자·숫자·로고·아이콘·기호를 포괄 금지 한 줄로 말한다.
- **말풍선도 생각풍선도 그리지 않는다** — 빈 말풍선도 안 된다. 자리가 있으면 모델이 거기에 글자를 넣는다(글자 금지를 명시했는데도 3컷에 "CRASH"가 박혔다). 앱이 대사를 직접 얹으므로 그림에 글자가 있으면 둘이 겹쳐 어느 쪽도 읽을 수 없다.
- 소리나 충격은 **움직임선과 자세로만** 나타낸다.
- **사람과 동작을 각 칸의 위 3분의 2에 두고, 아래는 바닥·가구 같은 평범한 배경으로 둔다.**

**금지할 물건의 이름을 프롬프트에 쓰지 않는다.** 하지 말라는 말도 그 물건을 모델에게 떠올리게 한다. 실제로 "각 칸의 아래 4분의 1은 비워 둔다(앱이 자막을 얹는다)"라고 적었더니 모델이 네 칸 아래에 **자막 띠와 자물쇠·플레이어 아이콘을 직접 그렸다.** 그래서 "자막·워터마크·카메라 UI 금지" 같은 나열을 걷어내고, 포괄 금지 한 줄과 긍정 구도 지시로만 말한다.

**놓치면 안 되는 세 가지**

- **대사(`dialogue`)는 이미지 프롬프트에 절대 넣지 않는다.** 대사 글자를 보여 주면 모델은 그것을 그림에 써 넣으려 든다. 대사는 앱이 그림 위에 얹는다.
- **프롬프트는 영어로 짠다** — 이미지 모델이 영어 지시를 더 안정적으로 따른다. 한국어인 인물표·배경표·장면 묘사는 영어 골격 안에 그대로 끼워 넣는다.
- **네 칸의 인물이 같아지는 것은 같은 문장을 그대로 반복해서 얻는다.** 인물 문장과 이름표를 네 칸 묘사에 **똑같이** 반복한다. 말을 바꿔 쓰면 칸마다 다른 사람이 나온다.

그리고 **사용자별 호출 횟수를 제한한다**(429). 이미지 생성은 호출마다 비용이 들고 앱은 막을 수 없다.

### API-73 `POST /api/videos/{videoId}/transcript` **[회수 — 만들지 않는다]**

> **번호 회수 주의.** API-73은 자동 자막(FN-A39)을 서버가 전사해 주는 엔드포인트로 제안됐으나,
> **한 줄도 구현되기 전에 회수됐다.** 폰에서 도는 ML Kit 음성 인식이 대신했다 — 같은 영상에서
> whisper를 CER 23.3% 대 35.0%로, 속도는 약 18초 대 235초로 앞질렀으니 오디오를 서버까지
> 보낼 이유가 없어졌다(커밋 `3bb0a47`). **이 번호는 다시 쓰지 않는다.**

- 서버에 이 엔드포인트를 만들지 않는다. 앱 쪽 통로(`transcript_api.dart`, `ApiClient.createTranscript`)도 함께 지웠다.
- 자막의 현재 계약은 서버 API가 아니라 **앱 코드**다(`features/stt/*`). `03-기능명세서.md`의 FN-A39를 볼 것.
- 자막 전용으로 예약했던 에러 코드 `TRANSCRIPT_RATE_LIMIT_EXCEEDED`·`TRANSCRIPT_GENERATION_FAILED`도 함께 회수됐다.
- 옛 문서나 커밋 메시지에 나오는 "API-73"은 이 회수된 제안을 가리킨다. 리포트 제안이 API-51에서 API-62로
  옮겨 간 것과 같은 원칙(번호는 되돌려 쓰지 않는다)이지만, 이쪽은 옮긴 게 아니라 **없앤 것**이다(12절 ID 검증).

---

## 7. MVP ⑥ 편집 영상 다운로드

### 사용자 흐름

1. 편집을 마치면 결과 영상을 기기 갤러리에 저장한다.
2. 저장된 영상은 갤러리에서 다른 앱으로 공유한다(앱 안에 별도 공유 기능은 없다).
3. 원본 클립이 별도로 필요하면 서버에서 다운로드한다.

### API-32 `POST /api/videos/{videoId}/download-url`

- 인증: 사용자 JWT
- 요청: PathVariable `videoId`
- 응답: `200 SignedUrlResponse` (API-31과 동일 스키마, `response-content-disposition=attachment` 쿼리가 추가된 URL)
- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `VIDEO_NOT_READY`, 503 `OBJECT_STORAGE_UNAVAILABLE`
- 비고: 재생 URL과 동일 TTL(5분). 앱은 이 URL을 외부 브라우저/앱으로 실행하며, 편집 결과물 자체는 네이티브 저장 경로(MediaStore)로 기기 갤러리에 저장한다(서버 API 불요).

---

## 8. MVP ⑦ 통계 / 리포트

### 사용자 흐름

1. 캘린더에서 날짜별 저장 영상 개수를 확인한다(API-27 재사용).
2. 웃음 리포트 화면에서 전체 감지 수·웃음이 있던 날 수·최근 감지 목록·연간 히트맵(웃음 잔디)을 확인한다. 주간 웃음 집계는 기본이 **가족 전체 합산(API-80)**이고, 금고에 기기가 둘 이상이면 "가족 전체 / 이 기기만" 토글이 나타난다(기기만 볼 때는 API-46 `type=LAUGHTER`). 가족 합산에서는 기기별 분해 카드가 함께 표시되며, 서버 집계가 실패하면 단말 집계로 폴백한다. API-33 통계는 홈 통계 카드에 쓰인다.
3. Flutter 리포트 화면은 기존 영상 목록에서 `LAUGHTER` 영상을 단말 집계해 전체 횟수, 최근 날짜별 횟수, 웃음 잔디와 날짜별 영상을 표시한다.
4. 주간/월간·시간대 분포·베스트 클립을 서버에서 집계하는 기능은 **API-62 제안·미구현** 범위다.

### API-27 `GET /api/videos` — 캘린더 범위 조회로 재사용

- 스키마는 4절(이벤트 영상 확인)의 API-27과 완전히 동일하다.
- 캘린더 화면은 `deviceId` + 월 범위(`from`~`to`)만 지정해 호출하고, 응답의 `items`를 날짜별로 집계해 표시한다.

### API-33 `GET /api/devices/{deviceId}/stats`

- 인증: 사용자 JWT
- 요청: RequestParam `from`,`to`(LocalDate, 옵션), `timeZone`(옵션)

응답: `200 VideoStatsResponse`

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

### API-74 `GET /api/schedules` — 캘린더 일정 목록

- 인증: 사용자 JWT
- 요청: 없음(사용자가 활성 구성원인 모든 금고의 일정)
- 응답: `200 List<ScheduleResponse>` — 날짜 오름차순

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| id | UUID | 필수 | 일정 ID |
| authorId | UUID | 필수 | 이 일정을 적은 사람. 앱이 수정·삭제 버튼을 가리는 데 쓴다 |
| authorName | String | 옵션 | 적은 사람의 표시 이름(서버가 `users`에서 조인) |
| title | String | 필수 | 제목(1~80자) |
| date | LocalDate | 필수 | 일정 날짜 |
| memo | String | 필수 | 메모(빈 문자열 가능, 최대 500자) |
| yearly | boolean | 필수 | 매년 반복 여부 |
| emoji | String | 필수 | 표시 이모지(기본 ❤️, 최대 16자) |

- 비고: 일정은 금고 공유다(2026-08-05 전환). `vault_id`가 공유 범위이고 `user_id`는 작성자다.
- 비고: 금고가 없던 시절에 적은 일정(`vaultId` 없음)은 적은 사람에게만 보인다. 마이그레이션이 옮길 금고가 없던 일정이라 개인 일정으로 남는다.

### API-75 `POST /api/schedules` — 캘린더 일정 등록

- 인증: 사용자 JWT
- 요청: `ScheduleRequest`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| title | String | 필수 | 1~80자, 앞뒤 공백 제거 |
| date | LocalDate | 필수 | 일정 날짜 |
| memo | String | 옵션(기본 빈 문자열) | 최대 500자 |
| yearly | Boolean | 옵션(기본 false) | 매년 반복 여부 |
| emoji | String | 옵션(기본 ❤️) | 최대 16자 |
| vaultId | UUID | 옵션 | 일정을 넣을 금고. 생략하면 사용자가 속한 금고가 하나일 때만 그것으로 정한다 |

- 응답: `201 ScheduleResponse`(API-74와 동일 스키마)
- 에러: 400 `VALIDATION_FAILED`(필드 형식), 403 `FORBIDDEN_ROLE`(그 금고의 구성원이 아님), 422 `VALIDATION_FAILED`(금고당 200개 상한 초과, 또는 여러 금고에 속해 있는데 `vaultId`를 생략)
- 비고: 금고 구성원 누구나 등록한다.

### API-76 `PUT /api/schedules/{scheduleId}` — 캘린더 일정 수정

- 인증: 사용자 JWT
- 요청: PathVariable `scheduleId` + `ScheduleRequest`(API-75와 동일)
- 응답: `200 ScheduleResponse`
- 에러: 403 `FORBIDDEN_ROLE`(적은 사람도 OWNER도 아님), 404 `RESOURCE_NOT_FOUND`(없거나 볼 수 없는 일정)
- 비고: 일정을 적은 사람 또는 금고 OWNER만 수정한다.

### API-77 `DELETE /api/schedules/{scheduleId}` — 캘린더 일정 삭제

- 인증: 사용자 JWT
- 응답: `204`
- 에러: 403 `FORBIDDEN_ROLE`(적은 사람도 OWNER도 아님), 404 `RESOURCE_NOT_FOUND`(없거나 볼 수 없는 일정)
- 비고: 일정을 적은 사람 또는 금고 OWNER만 삭제한다.

### API-62 `GET /api/devices/{deviceId}/laugh-report` **[제안]**

> **[제안]** — 구현된 FN-A38 Flutter 화면의 단말 집계를 FN-S26 서버 집계로 확장하기 위한 API 초안이다. 서버 endpoint·DTO·service는 미구현 상태이며, 기존 API-33(`VideoStatsService`)·API-46(`EventStatsService`)의 집계 로직과 `device_events` 데이터를 확장 기반으로 검토할 수 있다. 베스트 클립의 실제 재생 URL 발급은 기존 **API-31을 재사용**한다(이 API의 응답에는 재생 URL을 직접 담지 않는다).

- 인증: 사용자 JWT **[제안]**
- 요청: PathVariable `deviceId` + RequestParam **[제안]**

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| period | String | 필수 | `@Pattern "weekly\|monthly"` — 주간/월간 리포트 단위 |
| anchor | LocalDate | 옵션(기본값 오늘) | 기준 날짜. `period=weekly`면 해당 주(월요일 시작), `monthly`면 해당 월 전체를 집계 범위로 계산 |
| timeZone | String | 옵션(기본값 기기 타임존) | 시간대별 분포 슬롯 계산에 사용 |
| bestClipLimit | int | 옵션(기본 5, 1~20) | 베스트 클립 상위 N개 개수 |

응답: `200 LaughReportResponse` **[제안]**

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| deviceId | UUID | 필수 | 기기 ID |
| period | String | 필수 | `weekly`/`monthly` |
| rangeFrom | LocalDate | 필수 | 집계 시작일 |
| rangeTo | LocalDate | 필수 | 집계 종료일 |
| summary.laughCount | long | 필수 | 이번 기간 웃음(이벤트) 횟수 합계 |
| summary.previousLaughCount | long | 필수 | 직전 기간(전주/전월) 웃음 횟수 합계 |
| summary.changeRate | Double | 옵션(nullable) | 전주/전월 대비 증감률(%, 직전 값이 0이면 null) |
| hourlyDistribution | List\<HourlyCount\> | 필수 | 시간대별 분포 24슬롯(0~23시), 각 항목 `{hour:int, count:long}` |
| bestClips | List\<BestClip\> | 필수 | 베스트 클립 상위 N개(정렬 기준: 웃음 트리거 강도/최신순 등 상세 설계 시 확정) |
| bestClips[].videoId | UUID | 필수 | 영상 ID(API-31 재생 URL 발급 시 사용) |
| bestClips[].title | String | 필수 | 영상 제목 |
| bestClips[].occurredAt | Instant | 필수 | 웃음 감지(발생) 시각 |
| bestClips[].durationMs | Long | 옵션(nullable) | 클립 길이(ms) |
| bestClips[].thumbnailUrl | String | 옵션(nullable) | 썸네일 URL |

- 에러(제안) **[제안]**: 404 `RESOURCE_NOT_FOUND`, 422 `VALIDATION_FAILED`(period 미지원/anchor 형식 오류/bestClipLimit 범위 밖)
- 비고: 베스트 클립을 탭했을 때 실제 재생은 `bestClips[].videoId`로 **API-31**(`POST /api/videos/{videoId}/play-url`)을 호출해 서명 재생 URL을 새로 발급받는다 — 이 API 자체가 재생 가능한 URL을 내려주지 않는다.

---

## 9. 가족 공유 API

추억 금고 단위로 **OWNER / MEMBER** 2개 역할이 존재한다. 멤버십·초대·권한 판정은 금고에 귀속되며, 아래 기기 경로 API는 해당 기기가 속한 금고의 멤버십을 다룬다. 앱은 금고 경로(API-63~68, 이 절 마지막 참고)를 기본으로 호출하고 기기 경로는 금고 정보가 없을 때의 폴백으로 쓴다. 가입은 초대 승인제로만 이루어지며, 링크만으로 자동 가입되는 경로는 없다. 초대로 만들어지는 역할은 항상 MEMBER다.

### 사용자 흐름

1. OWNER가 이메일을 지정해 초대를 발송한다.
2. 초대받은 사용자는 받은 초대함에서 목록을 확인하고 수락 또는 거절한다.
3. 수락 시점에 실제 멤버십이 생성된다.
4. 별도로 "내 계정으로 초대해달라"는 요청 링크를 만들어 공유할 수 있지만, 링크 자체는 멤버십을 만들지 않는다.

### API-14 `POST /api/devices/{deviceId}/invitations`

- 인증: 사용자 JWT(OWNER)
- 요청

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| email | String | 필수 | `@NotBlank @Email @Size≤320` |
| membershipRequestToken | String | 옵션 | `@Size≤200` |

> `role` 필드는 받지 않는다. 초대로 만들어지는 역할은 항상 `MEMBER`로 고정된다(DB 제약 `ck_invitations_member_only`).

응답: `201 InvitationResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| id | UUID | 필수 | 초대 ID |
| deviceId | UUID | 필수 | 기기 ID |
| deviceName | String | 필수 | 기기 이름 |
| vaultId | UUID | 필수 | 초대 대상 금고 ID |
| vaultName | String | 필수 | 금고 이름 |
| inviteeEmail | String | 필수 | 초대받는 이메일 |
| role | String | 필수 | MEMBER 고정 |
| inviter.id | UUID | 옵션(nullable) | 초대자 ID |
| inviter.email | String | 옵션 | 초대자 이메일 |
| inviter.displayName | String | 옵션 | 초대자 표시이름 |
| status | String | 필수 | PENDING/ACCEPTED/DECLINED/EXPIRED/REVOKED |
| expiresAt | Instant | 필수 | 만료 시각(초대 유효기간 7일) |
| createdAt | Instant | 필수 | 생성 시각 |

- 에러: 403 `FORBIDDEN_ROLE`, 422 `VALIDATION_FAILED`(이메일 형식 오류 등), 409 `ALREADY_DEVICE_MEMBER`, 409 `INVITATION_PENDING`, 409 `MEMBERSHIP_REQUEST_EMAIL_MISMATCH`, 404 `MEMBERSHIP_REQUEST_NOT_FOUND`

### API-15 `POST /api/membership-request-links`

- 인증: 사용자 JWT
- 요청: 없음
- 응답: `201 MembershipRequestLinkResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| token | String | 필수 | 요청 링크 토큰 |
| expiresAt | Instant | 필수 | 만료 시각 |

- 에러: 없음
- 비고: 요청자당 활성 링크 1개만 유지된다.

### API-16 `GET /api/membership-request-links/{token}`

- 인증: 사용자 JWT
- 요청: PathVariable `token`
- 응답: `200 MembershipRequestPreviewResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| email | String | 필수 | 요청자 이메일 |
| displayName | String | 필수 | 요청자 표시이름 |
| expiresAt | Instant | 필수 | 만료 시각 |

- 에러: 403 `OWNER_MEMBERSHIP_REQUIRED`, 404 `MEMBERSHIP_REQUEST_NOT_FOUND`

### API-17 `GET /api/membership-request-links/{token}/open`

- 인증: 공개(permitAll)
- 요청: PathVariable `token`(정규식 `[A-Za-z0-9_-]{43}`)
- 응답: `302 Redirect`(`Location: bbanggeut://membership-request/{token}`, 본문 없음)
- 에러: 형식 불일치 시 404(본문 없음)
- 비고: 이메일/공유 링크로 외부 브라우저가 열고, 앱은 리다이렉트 결과인 딥링크만 수신한다.

### API-18 `GET /api/devices/{deviceId}/invitations`

- 인증: 사용자 JWT(OWNER)
- 요청: PathVariable `deviceId`
- 응답: `200 List<InvitationResponse>` (API-14 응답 스키마와 동일)
- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`

### API-19 `DELETE /api/devices/{deviceId}/invitations/{invitationId}`

- 인증: 사용자 JWT(OWNER)
- 요청: PathVariable `deviceId`, `invitationId`
- 응답: `204 No Content`
- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`, 409 `INVITATION_NOT_PENDING`
- 비고: PENDING 상태의 초대만 취소 가능.

### API-20 `GET /api/invitations`

- 인증: 사용자 JWT
- 요청: 없음
- 응답: `200 List<InvitationResponse>`
- 에러: 없음

### API-21 `POST /api/invitations/{invitationId}/accept`

- 인증: 사용자 JWT
- 요청: PathVariable `invitationId`

응답: `200 DeviceMemberResponse`

| 필드명 | 타입 | 필수여부 | 설명 |
|---|---|---|---|
| id | UUID | 필수 | 멤버십 ID |
| deviceId | UUID | 옵션(nullable) | 기기 ID — 금고 경로(API-66) 조회 시 null일 수 있다 |
| vaultId | UUID | 옵션(nullable) | 금고 ID |
| user.id | UUID | 필수 | 사용자 ID |
| user.email | String | 필수 | 이메일 |
| user.displayName | String | 필수 | 표시이름 |
| role | String | 필수 | 역할 |
| status | String | 필수 | ACTIVE/REVOKED |
| joinedAt | Instant | 필수 | 가입 시각 |

- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `INVITATION_EXPIRED`, 409 `INVITATION_NOT_PENDING`

### API-22 `POST /api/invitations/{invitationId}/decline`

- 인증: 사용자 JWT
- 요청: PathVariable `invitationId`
- 응답: `204 No Content`
- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `INVITATION_NOT_PENDING`

### API-23 `GET /api/devices/{deviceId}/members`

- 인증: 사용자 JWT(멤버)
- 요청: PathVariable `deviceId`
- 응답: `200 List<DeviceMemberResponse>` (API-21 응답 스키마와 동일)
- 에러: 404 `RESOURCE_NOT_FOUND`

### API-24 `DELETE /api/devices/{deviceId}/members/{membershipId}`

- 인증: 사용자 JWT(OWNER)
- 요청: PathVariable `deviceId`, `membershipId`
- 응답: `204 No Content`
- 에러: 403 `FORBIDDEN_ROLE`, 404 `RESOURCE_NOT_FOUND`, 409 `OWNER_CANNOT_BE_REVOKED`, 409 `MEMBERSHIP_NOT_ACTIVE`
- 비고: OWNER는 추방 불가, 이미 비활성인 멤버십은 재추방 불가.

### 금고 경로 가족 공유 API (API-63~68)

앱이 기본으로 호출하는 금고 스코프 경로다. 요청·응답 스키마는 위 기기 경로의 대응 API와 동일하다(`InvitationResponse`, `DeviceMemberResponse` 공유).

| ID | 메서드/경로 | 응답 | 대응 기기 경로 |
|---|---|---|---|
| API-63 | `POST /api/vaults/{vaultId}/invitations` | `201 InvitationResponse` | API-14 |
| API-64 | `GET /api/vaults/{vaultId}/invitations` | `200 List<InvitationResponse>` | API-18 |
| API-65 | `DELETE /api/vaults/{vaultId}/invitations/{invitationId}` | `204` | API-19 |
| API-66 | `GET /api/vaults/{vaultId}/members` | `200 List<DeviceMemberResponse>` | API-23 |
| API-67 | `DELETE /api/vaults/{vaultId}/members/{membershipId}` | `204` | API-24 |
| API-68 | `POST /api/vaults/{vaultId}/transfer-ownership` | `204` | API-12 |

- API-68 요청 본문: `{newOwnerMembershipId}`(UUID, 필수)
- 금고 경로 고유 에러: 409 `ALREADY_VAULT_MEMBER`(이미 금고 구성원), 409 `TRANSFER_TARGET_NOT_ACTIVE_MEMBER`(이전 대상이 활성 구성원이 아님), 409 `ALREADY_OWNER`(대상이 이미 OWNER)

---

## 10. 기기·세션 유지에 필요한 공통 MQTT

토픽 베이스: `${app.mqtt.environment}/wj/v2`(예: `local/wj/v2`, `prod/wj/v2`), 브로커: Mosquitto + `dynamic-security` 플러그인. MQTT-01(commands)·MQTT-04(stream/events)는 8절(라이브 스트리밍)에서 다뤘으므로 여기서는 기기 상태·하트비트·등록·이벤트 등 나머지 `wj/v2` 토픽만 정리한다.

> **v2 마이그레이션**: 토픽 루트가 `wj/v1`→`wj/v2`, `schemaVersion`이 `1.0`→`2.0`으로 변경됐다. 백엔드는 `2.0`이 아닌 payload를 조용히 폐기한다.

| ID | 토픽(접미사) | 방향 | QoS | 요약 |
|---|---|---|---|---|
| MQTT-02 | `{base}/devices/+/status` | 기기→백엔드 | 1 | `{schemaVersion, deviceId, state: ONLINE\|OFFLINE, firmwareVersion?}`. 연결(ONLINE)/LWT(OFFLINE)/정상 종료 시 발행 |
| MQTT-03 | `{base}/devices/+/commands/ack` | 기기→백엔드 | 1 | `{schemaVersion, requestId, deviceId, status: ACCEPTED\|SUCCEEDED\|FAILED\|REJECTED\|EXPIRED, ...}`. 명령 수신·처리마다 발행 |
| MQTT-05 | `{base}/devices/+/heartbeat` | 기기→백엔드 | 0 | `{schemaVersion, deviceId, recording, uploadQueueDepth, bufferSeconds?, personCount?, firmwareVersion}`. 30초 주기이며 서버는 Redis presence를 90초 TTL로 갱신한다. TTL 만료는 별도 DB sweep 없이 OFFLINE을 뜻한다. |
| MQTT-06 | `{base}/devices/+/registration` | 기기→백엔드 | 1 | `{schemaVersion, deviceId, mode: ENABLED\|DISABLED, expiresAt?}`. 등록 코드 발급은 실제로 API-43(HTTP)으로만 이루어진다 |
| MQTT-07 | `{base}/devices/+/events` | 기기→백엔드 | 1 | `{schemaVersion, deviceId, eventId, type, occurredAt, confidence?, localClip, source}`. 웃음 감지→업로드 흐름은 실제로 API-25/26(HTTP)으로만 동작한다 |
| MQTT-08 | `$CONTROL/dynamic-security/v1` | 백엔드→브로커 | 1 | 기기별 MQTT 계정/ACL 생성·회전·비활성화(Mosquitto dynamic-security 관리 채널) |
| MQTT-09 | `$CONTROL/dynamic-security/v1/response` | 브로커→백엔드 | 1 | MQTT-08 발행에 대한 브로커 응답 |

기기별 MQTT 계정 ACL은 발행 권한을 `status,heartbeat,registration,events,stream/events,commands/ack`에, 구독 권한을 `commands`에만 부여한다 — 기기는 `wj/v2` 네임스페이스 밖(`homecam/v2`)으로는 이 ACL 체계가 적용되지 않는다(부록 A 참고).

---

## 11. 부록 A: 확장 API

MVP 7단계·가족 공유 밖이지만 API 자체는 존재하는 항목이다. ID·메서드·경로·용도만 한 줄로 축약했다. 상세 스키마는 as-built본(git 이력 `723bdbc`)을 참고한다.

### REST

| ID | 메서드/경로 | 용도(한 줄) |
|---|---|---|
| API-04 | `POST /api/auth/logout` | 로그아웃(세션 단위 무효화) |
| API-05 | `DELETE /api/auth/me` | 회원 탈퇴(소유 기기 있으면 거부) |
| API-09 | `GET /api/devices/{deviceId}` | 기기 단건 조회 |
| API-10 | `PATCH /api/devices/{deviceId}` | 기기 이름/보관기간 변경(OWNER) |
| API-12 | `POST /api/devices/{deviceId}/transfer-ownership` | 기기 소유권 이전 |
| API-13 | `DELETE /api/devices/{deviceId}` | 금고에서 물리 기기 연결 해제. 금고·영상·구독·금고 멤버십은 보존 |
| API-28 | `GET /api/videos/{videoId}` | 영상 단건 상세 조회 |
| API-29 | `PATCH /api/videos/{videoId}` | 영상 메타데이터(제목/메모/즐겨찾기) 수정 |
| API-30 | `DELETE /api/videos/{videoId}` | 영상 삭제(OWNER, 비동기) |
| API-39 | `GET /api/devices/{deviceId}/subscription` | 구독 상태 조회 |
| API-40 | `PUT /api/devices/{deviceId}/subscription` | 구독 활성화 |
| API-41 | `DELETE /api/devices/{deviceId}/subscription` | 구독 해지 |
| API-42 | `GET /api/devices/{deviceId}/home-summary` | 홈 요약 카드 집계 |
| API-46 | `GET /api/devices/{deviceId}/event-stats` | 이벤트 전용 통계. `from`·`to`·`timeZone`에 더해 `type`(예 LAUGHTER) 필터 지원 — detectedCount·dailyCounts만 거르고 byType은 전체 분포 유지 |
| API-47 | `POST /internal/admin/devices` | (내부 관리자 키) 기기 프로비저닝 |
| API-48 | `POST /internal/admin/devices/{deviceId}/credentials/rotate` | (내부 관리자 키) 자격증명 강제 회전 |
| API-49 | `DELETE /internal/admin/devices/{deviceId}/credentials` | (내부 관리자 키) 자격증명 폐기 |
| API-50 | `GET /api/devices/{deviceId}/access-logs` | 접근 기록 커서 조회 |
| API-51 | `GET /api/vaults/{vaultId}/subscription` | 금고 구독 상태 조회 |
| API-52 | `PUT /api/vaults/{vaultId}/subscription` | 금고 구독 활성화 |
| API-53 | `DELETE /api/vaults/{vaultId}/subscription` | 금고 구독 해지 |
| API-54 | `GET /api/vaults/{vaultId}/access-logs` | 금고 접근 기록 커서 조회 |
| API-55 | `POST /api/auth/password/change` | 비밀번호 변경(로그인 상태, 현재 비밀번호 확인) |
| API-56 | `POST /api/auth/password/forgot` | 비밀번호 재설정 링크 발급 요청(공개) |
| API-57 | `POST /api/auth/password/reset` | 토큰으로 비밀번호 재설정(공개) |
| API-58 | `GET /api/notifications` | 알림 목록 조회(최신순, limit 기본 30·최대 100) |
| API-59 | `GET /api/notifications/unread-count` | 안 읽은 알림 개수 |
| API-60 | `PATCH /api/notifications/{notificationId}/read` | 알림 1건 읽음 처리 |
| API-61 | `PATCH /api/notifications/read-all` | 전체 읽음 처리 |
| API-69 | `PUT /api/notifications/push-tokens` | FCM 푸시 토큰 등록(`{installationId, token, platform}`, 204) — 로그인·세션 복원 시 앱이 자동 호출 |
| API-70 | `DELETE /api/notifications/push-tokens/{installationId}` | 푸시 토큰 해제(204) — 로그아웃·탈퇴 시 앱이 자동 호출 |
| API-78 | `GET /api/notifications/preferences` | 알림 설정 조회(`{anniversaryAlerts, weeklyReport, newMemoryAlerts}`) — 저장 행이 없으면 모두 true |
| API-79 | `PUT /api/notifications/preferences` | 알림 설정 저장(세 토글 일괄, 200에 저장값 반환) — `newMemoryAlerts=false`면 새 영상 푸시 발송 대상에서 제외 |
| API-81 | `POST /api/videos/{videoId}/edits` | 편집 완성본 업로드 예약 — 원본에서 금고·기기·보관 기준을 상속한 `EDIT_OUTPUT` 행을 만들고 서명 URL 발급. 서명에 `Content-Type`만 들어간다(백그라운드 업로더가 헤더를 못 붙임). 완료 통보 없이 서버가 도착을 훑어 READY로 승격 |
| API-82 | `GET /api/vaults/{vaultId}/edits` | 금고의 편집 완성본 목록(최신순 100건). 올라가는 중(UPLOADING)과 실패(FAILED)도 함께 준다 — 업로드 진행 상황이 상단 알림으로만 나가서, 알림을 끈 기기에서는 목록이 유일한 단서다 |
| API-83 | `GET /api/videos/{videoId}/comments` | 영상 댓글 목록 — 작성자 표시 이름은 서버가 `users`에서 조인 |
| API-84 | `POST /api/videos/{videoId}/comments` | 영상 댓글 작성 — 작성자는 토큰의 사용자 UUID(앱이 보낸 이름을 믿지 않는다), 작성자 외 금고 구성원에게 알림·FCM |
| API-85 | `PATCH /api/videos/{videoId}/comments/{commentId}` | 영상 댓글 수정 — 쓴 사람만. OWNER에게도 열지 않는다(남의 말을 고쳐 쓰는 것과 지우는 것은 다른 일이다) |
| API-86 | `DELETE /api/videos/{videoId}/comments/{commentId}` | 영상 댓글 삭제 — 쓴 사람 또는 금고 OWNER. 부적절한 댓글은 OWNER가 지운다 |
| API-80 | `GET /api/vaults/{vaultId}/event-stats` | 금고(가족) 단위 이벤트 통계 — API-46 계약 + 기기별 분해(`byDevice`). Binding 기간(bound_at~ended_at)과 겹치는 이벤트만 집계해 기기 양도 후에도 과거 금고 통계가 오염되지 않음. **앱 웃음 리포트의 "가족 전체" 토글이 사용** |

#### 비밀번호 API 동작 규칙 (API-55~57)

| 항목 | 변경(API-55) | 재설정(API-56·57) |
|---|---|---|
| 인증 | 사용자 JWT + 현재 비밀번호 | 불필요(이메일로 받은 1회용 토큰) |
| 요청 | `currentPassword`, `newPassword`(10~72자) | 56: `email` / 57: `token`(32~200), `newPassword` |
| 응답 | `204` | 56: `202` / 57: `204` |
| 세션 처리 | 현재 세션만 유지, 나머지 폐기 | **전 세션 폐기** |
| 에러 | 401 `INVALID_CREDENTIALS`, 422 `PASSWORD_UNCHANGED` | 401 `INVALID_PASSWORD_RESET_TOKEN` |

- 재설정 토큰은 **30분 TTL·1회용**이며, DB에는 원문이 아닌 SHA-256 해시만 저장한다(`password_reset_tokens`).
- API-56은 **가입되지 않은 이메일에도 동일하게 `202`를 반환**한다. 계정 존재 여부를 노출하지 않기 위함이며, 로그인(API-02)의 동일 메시지 원칙과 같은 이유다.
- 새 forgot 요청은 이전 토큰을 먼저 만료시키므로 항상 최신 링크 1개만 유효하다.
- 메일 서버(`spring.mail.host`)가 비어 있으면 발송을 건너뛰고 경고 로그만 남긴다(개발 환경 대응).

#### 알림 생성 시점 (API-58~61은 조회·읽음 전용)

알림을 만드는 별도 API는 없다. 서버가 다음 시점에 자동으로 생성한다.

| 종류 | 생성 시점 | 대상 | dedupe_key |
|---|---|---|---|
| `LAUGHTER_VIDEO_READY` | 영상 업로드 완료(API-26)로 `READY` 확정 + `triggerType=LAUGHTER` | 해당 기기의 활성 구성원 **전원** | `laughter-video:{videoId}` |
| `INVITATION_RECEIVED` | 초대 발송(API-14) | 초대받은 이메일의 사용자 1명 | `invitation:{invitationId}` |
| `ANNIVERSARY` | 매일 09:00 KST 스케줄러 — 일정(API-74)의 날짜가 오늘이거나 매년 반복이 월·일로 일치 | 일정을 등록한 사용자(설정 `anniversaryAlerts` 존중) | `anniversary:{scheduleId}:{year}` |
| `WEEKLY_REPORT` | 매주 월요일 09:00 KST 스케줄러 — 지난주(월~일) 금고 기기들의 LAUGHTER 이벤트 합계 | 활성 금고 멤버십 + 활성 기기 Binding이 있는 사용자(설정 `weeklyReport` 존중) | `weekly-report:{userId}:{ISO주차}` |

`notifications` 테이블에 `UNIQUE (user_id, dedupe_key)`가 있고 INSERT에 `ON CONFLICT DO NOTHING`이 붙어 있어, 같은 업로드 완료가 여러 번 들어와도 사용자별 알림은 1건만 남는다.

알림 설정(API-78·79)의 동작: `newMemoryAlerts`를 끈 사용자는 `LAUGHTER_VIDEO_READY` **푸시** 대상에서 빠지지만 인앱 알림함에는 계속 쌓인다. `anniversaryAlerts`·`weeklyReport`를 끈 사용자는 해당 스케줄러의 대상 조회에서 제외되어 **인앱 알림도 만들지 않는다**(주기 리포트라 알림함에만 쌓이는 것도 소음이다). 설정 행이 없는 사용자는 모두 켜진 것으로 본다(단말 저장 전용이던 시절 사용자가 푸시를 잃지 않게 하기 위함).

앱 알림함은 API-58(목록)·API-60(개별 읽음)·API-61(전체 읽음)을 사용하고, FCM payload의 알림 종류에 따라 해당 화면(영상 상세/받은 초대함)으로 이동한다. API-59(미읽음 개수)는 아직 앱에서 호출하지 않는다.

### 실험 MQTT(`homecam/v2`, 6개)

운영 배포 스크립트가 `MQTT_HOST=`(빈 값)로 넘겨 코드 경로 자체가 비활성화된 실험 단계 산출물이다(YOLO 팬틸트 추적·이벤트 퓨전용). `wj/v2` ACL 체계 밖이며 백엔드는 전혀 구독하지 않는다.

| ID | 토픽(접미사) | 용도(한 줄) |
|---|---|---|
| MQTT-10 | `homecam/v2/{device_id}/ai/vision/state` | YOLO 비전 상태 발행(추적 대상/좌표) |
| MQTT-11 | `homecam/v2/{device_id}/control/framing/target` | 팬틸트 프레이밍 목표값 발행(구독자 없음) |
| MQTT-12 | `homecam/v2/{device_id}/ai/vision/status` | YOLO 컴포넌트 온/오프라인(LWT) |
| MQTT-13 | `homecam/v2/{device_id}/ai/laughter/detected` | YAMNet 웃음 감지 이벤트(실험 경로, 운영은 API-25/26 HTTP로 대체) |
| MQTT-14 | `homecam/v2/{device_id}/ai/status` | YAMNet 컴포넌트 온/오프라인(LWT) |
| MQTT-15 | `homecam/v2/{device_id}/events/memory-candidate` | 웃음+비전 컨텍스트 퓨전 결과 발행 |

---

## 12. 부록 B: 구현 현황

| # | MVP 단계 | 상태 | 비고 |
|---|---|---|---|
| 1 | 회원가입 / 로그인 | 구현됨 | API-01~03 전체 동작 |
| 2 | 기기 등록 | 구현됨 | API-08, 43~45, 07, 11 포함 전체 동작 |
| 3 | 홈에서 라이브 스트리밍 시청 | 구현됨 | API-34~38, MQTT-01/04, RTSPS→WebRTC/WHEP 전용 |
| 4 | 이벤트(웃음) 감지 영상 확인 | 구현됨 | API-25~27, 31 포함 전체 동작 |
| 5 | 영상 편집 | 구현됨 | 수동 편집(FN-A21)과 자동 자막(FN-A39)은 서버 API 불요 — 편집은 로컬 처리, 자막은 폰의 ML Kit 온디바이스 인식으로 **끝난다.** 4컷 만화(FN-A40)는 **API-71·API-72로 구현됐다**(앱·백엔드·만화 워커) |
| 6 | 편집 영상 다운로드 | 구현됨 | API-32 |
| 7 | 통계 / 리포트 | 부분 구현 | API-27·33 구현, 주간 웃음 리포트는 API-46(`type=LAUGHTER`) 서버 집계 사용(실패 시 단말 폴백), 캘린더 일정은 API-74~77. **API-62(시간대 분포·베스트 클립) 서버 집계는 미구현(제안 초안)** |
| 가족 공유 | API-14~24, 63~68 | 구현됨 | 초대/수락/거절/구성원 관리 전체 동작(앱은 금고 경로 API-63~68을 기본 사용) |

MVP 7단계의 API 중 미구현은 **API-62(리포트 서버 집계)** 하나뿐이다. Flutter 리포트 화면 자체는 기존 영상 목록 데이터로 동작한다. **API-71·API-72(4컷 만화)는 구현됐다** — 앱은 기본으로 실서버를 부르며(`--dart-define=COMIC_SERVER=false`면 견본), 만화 워커에 모델 키(`GMS_KEY`)가 없으면 실제 호출이 실패한다. **자동 자막(FN-A39)은 서버 없이 폰에서 완결됐다** — 한때 예약해 둔 전사 엔드포인트 API-73은 구현 전에 회수됐다(6절).

### API-06 제외 사유

프런트엔드가 `PATCH /api/auth/me`(프로필 이름 수정)를 호출하지만 서버에 대응 매핑이 없다(as-built 교차검증에서 확인된 사실). **존재하지 않는 API이므로 본 문서(본문·부록 A 모두)에서 제외**했다. 부록 A(`03-기능명세서.md`)의 FN-A26(프로필 이름 수정, 미구현)이 이 결함을 별도로 추적한다.

### ID 검증

- 본문(2~10절)에 배치된 API ID: 01, 02, 03, 07, 08, 11, 14~24, 25~27, 31~38, 43~45, 63~68, 74~77, (신규)62, (신규)71, 72 — 41개 + 신규 3개. **API-73은 스키마 없이 회수 사유만 남은 자리이므로 세지 않는다.**
- 부록 A에 배치된 API ID: 04, 05, 09, 10, 12, 13, 28~30, 39~42, 46~61, 69, 70, 78~84 — 38개.
- 합계 41 + 38 = 79개 + 신규 3개(리포트 제안 API-62, 만화 API-71·72) = **82개**다. 번호 폭은 API-01~84(84개)이고, 그 안에 **스키마가 없는 자리가 둘** 있다 — **API-06(결번, 서버에 매핑이 없다)과 API-73(회수, 구현 전에 없앴다)**. 84에서 2를 빼면 **82개로 맞는다. 번호의 최대는 API-84이고, 회수된 API-73은 재사용하지 않는다**. 중복 배치 없음(API-27만 4절·8절에서 의도적으로 재사용 표기, API-32는 6·7절에서 재사용 표기 — 동일 ID를 다른 단계에서 참조만 할 뿐 스키마는 한 곳에만 정의).
- MQTT ID: 3절(01, 04) + 10절(02, 03, 05~09) + 부록 A(10~15) = 2 + 7 + 6 = 15개, MQTT-01~15 전수 반영, 중복 없음.
- 리포트 제안은 처음에 max(API-50) 다음 번호인 API-51을 받았으나, 이후 금고 구독·접근 기록(API-51~54)이 같은 번호를 가져가 중복이 생겼다. 리포트 제안은 미구현 초안이고 금고는 구현·병합된 API이므로, 리포트 제안을 **API-62**로 옮겨 정리했다. 비밀번호(API-55~57)·알림(API-58~61)에 이어 금고 가족 공유(API-63~68)·푸시 토큰(API-69, 70)을 새로 문서화해 max는 **API-70**이 되었다.
- **4컷 만화·자동 자막 제안도 같은 이유로 옮겼다.** 만화 구성·그림과 서버 전사는 처음에 옛 max(API-51) 다음인 **API-52·53·54**를 받았으나, 그 번호 역시 금고 구독(API-51~53)·금고 접근 기록(API-54)과 겹쳤다. 리포트 제안과 같은 원칙(구현·병합된 API가 번호를 지킨다)으로 세 개를 max(API-70) 다음인 **API-71(만화 구성)·API-72(만화 그림)·API-73(자막 전사)**로 옮겼다. 이로써 max는 **API-73**이 되었다.
- **그러고 나서 API-73은 구현 전에 회수됐다.** ML Kit 온디바이스 인식이 자막을 폰에서 끝내 버려 서버 전사가 필요 없어졌다(6절 API-73). **번호는 다시 쓰지 않는다** — API-06을 결번으로 비워 둔 것과 같은 처리이며, 그래서 번호 폭(01~73)은 줄지 않고 비어 있는 자리만 하나 늘었다. 다음에 새 API를 붙일 때는 **API-74**부터 쓴다.
- **API-74~80은 그 규칙대로 붙였다.** 캘린더 일정 CRUD(API-74~77, 8절), 알림 설정(API-78·79, 부록 A), 금고 단위 통계(API-80, 부록 A)가 2026-08-04에 구현·문서화됐다. 이로써 max는 **API-80**이다.

---

## 참고 — 파생 문서 동기화 고지

본 문서(04)를 고칠 때는 파생본인 `자료/docs/ai에게 입력용 문서/04-api-spec.md`도 같은 내용으로 함께 갱신한다. 사람용 문서가 사실·ID·구조의 1차 원천이다.
