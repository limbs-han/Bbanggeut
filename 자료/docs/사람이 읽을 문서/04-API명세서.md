# API 명세서

> 기준: to-be 기획(MVP 2026-07-27 확정) · 코드 현황 참조 커밋 cb65eff

본 문서는 **목표(to-be) 기준**의 API 명세서다. `03-기능명세서.md`에서 정의한 **MVP 7단계**를 뼈대로, 각 단계에서 사용하는 REST API·MQTT 토픽·미디어 경로를 실제 요청/응답 스키마와 함께 배치한다.

- API/MQTT ID는 기존 as-built 문서(API-01~50, MQTT-01~15)의 번호를 그대로 재사용한다. 문서 배치는 MVP 7단계 순서로 재구성했지만 번호 자체는 바뀌지 않았다.
- 프로토콜 사실(경로·요청/응답 필드·에러 코드·MQTT 토픽·미디어 경로)은 코드에서 직접 검증된 as-built본(git 이력 `723bdbc`)에서 그대로 가져온 것이며, 이번 재작성에서 재검증하지 않았다.
- **신규 API-62**(`GET /api/devices/{deviceId}/laugh-report`)은 구현된 FN-A38 Flutter 화면의 단말 집계를 FN-S26 서버 집계로 확장하기 위한 **초안**이다. 표·본문 전체에 **[제안]** 배지를 붙여 기존 구현 API와 구분한다.
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
- 운영 API는 `playUrl`을 반환하지 않으며 앱에는 HLS 재생 경로가 없다. `whepUrl`이 없거나 WHEP/ICE 연결이 실패하거나 SDP answer의 오디오가 원격 송신 방향(`sendonly`/`sendrecv`)이 아니거나, 연결 후 2초 안에 inbound audio RTP가 없으면 연결 실패를 표시하고 사용자가 재시도할 수 있게 한다.
- 연결 성공은 원격 video/audio track과 실제 inbound audio RTP 수신이 모두 확인된 시점이다. 홈 라이브는 기본 음소거가 아니며, 사용자가 음소거 버튼으로 직접 제어한다.
- 송출 오디오는 WebRTC 호환 Opus를 사용해야 한다. AAC-only 송출은 MediaMTX가 WebRTC 오디오 트랙을 건너뛸 수 있으므로 지원하지 않는다.
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
| objectETag | String | 옵션 | `@Size≤200` |

- 응답: `200 VideoResponse` (API-27 목록의 개별 항목과 동일 스키마, 아래 참고)
- 에러: 404 `RESOURCE_NOT_FOUND`, 409 `VIDEO_STATE_CONFLICT`(Vault 기반 READY 전환 실패 포함), 409 `IDEMPOTENCY_KEY_MISMATCH`, 409 `UPLOAD_INTEGRITY_MISMATCH`, 503 `OBJECT_STORAGE_UNAVAILABLE`

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
| description | String | 옵션(nullable) | 메모 |
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
2. 앱 자체 편집 화면에서 자르기·화면 비율·음량·자막·필터·이모지 스티커 수동 편집을 진행한다.
3. 편집 결과는 폰에 로컬로 저장된다.

**별도 서버 API는 필요하지 않다** — 편집은 전적으로 폰에서 이루어지며, 원본 다운로드는 ⑥ 단계와 동일한 API-32(다운로드 URL)를 재사용한다.

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
2. 웃음 리포트 화면에서 전체 감지 수·웃음이 있던 날 수·최근 감지 목록·연간 히트맵(웃음 잔디)을 확인한다. 이 화면의 집계는 단말에서 이루어지고, API-33 통계는 홈 통계 카드에 쓰인다.
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
| API-46 | `GET /api/devices/{deviceId}/event-stats` | 이벤트 전용 통계(현재 클라이언트는 API-33만 사용) |
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

알림을 만드는 별도 API는 없다. 서버가 다음 두 시점에 자동으로 생성한다.

| 종류 | 생성 시점 | 대상 | dedupe_key |
|---|---|---|---|
| `LAUGHTER_VIDEO_READY` | 영상 업로드 완료(API-26)로 `READY` 확정 + `triggerType=LAUGHTER` | 해당 기기의 활성 구성원 **전원** | `laughter-video:{videoId}` |
| `INVITATION_RECEIVED` | 초대 발송(API-14) | 초대받은 이메일의 사용자 1명 | `invitation:{invitationId}` |

`notifications` 테이블에 `UNIQUE (user_id, dedupe_key)`가 있고 INSERT에 `ON CONFLICT DO NOTHING`이 붙어 있어, 같은 업로드 완료가 여러 번 들어와도 사용자별 알림은 1건만 남는다.

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
| 5 | 영상 편집 | 구현됨 | 서버 API 불요(로컬 편집) |
| 6 | 편집 영상 다운로드 | 구현됨 | API-32 |
| 7 | 통계 / 리포트 | 부분 구현 | 기존 API-27·33과 Flutter 단말 집계 화면은 구현. **API-62 서버 집계는 미구현(제안 초안)** |
| 가족 공유 | API-14~24, 63~68 | 구현됨 | 초대/수락/거절/구성원 관리 전체 동작(앱은 금고 경로 API-63~68을 기본 사용) |

MVP 7단계의 API 중 새로 제안된 **API-62(리포트 서버 집계)**는 미구현이다. Flutter 리포트 화면 자체는 기존 영상 목록 데이터로 동작한다.

### API-06 제외 사유

프런트엔드가 `PATCH /api/auth/me`(프로필 이름 수정)를 호출하지만 서버에 대응 매핑이 없다(as-built 교차검증에서 확인된 사실). **존재하지 않는 API이므로 본 문서(본문·부록 A 모두)에서 제외**했다. 부록 A(`03-기능명세서.md`)의 FN-A26(프로필 이름 수정, 미구현)이 이 결함을 별도로 추적한다.

### ID 검증

- 본문(2~10절)에 배치된 API ID: 01, 02, 03, 07, 08, 11, 14~24, 25~27, 31~38, 43~45, 63~68, (신규)62 — 37개 + 신규 1개.
- 부록 A에 배치된 API ID: 04, 05, 09, 10, 12, 13, 28~30, 39~42, 46~61, 69, 70 — 31개.
- 합계 37 + 31 = 68개 + 리포트 제안 API-62 = **API-01~70 중 API-06(의도적 제외, 위 사유 참고)만 결번인 69개**다. 중복 배치 없음(API-27만 4절·8절에서 의도적으로 재사용 표기, API-32는 6·7절에서 재사용 표기 — 동일 ID를 다른 단계에서 참조만 할 뿐 스키마는 한 곳에만 정의).
- MQTT ID: 3절(01, 04) + 10절(02, 03, 05~09) + 부록 A(10~15) = 2 + 7 + 6 = 15개, MQTT-01~15 전수 반영, 중복 없음.
- 리포트 제안은 처음에 max(API-50) 다음 번호인 API-51을 받았으나, 이후 금고 구독·접근 기록(API-51~54)이 같은 번호를 가져가 중복이 생겼다. 리포트 제안은 미구현 초안이고 금고는 구현·병합된 API이므로, 리포트 제안을 **API-62**로 옮겨 정리했다. 비밀번호(API-55~57)·알림(API-58~61)에 이어 금고 가족 공유(API-63~68)·푸시 토큰(API-69, 70)을 새로 문서화해 현재 max는 **API-70**이다.

---

## 참고 — 파생 문서 동기화 고지

본 문서(04)를 고칠 때는 파생본인 `자료/docs/ai에게 입력용 문서/04-api-spec.md`도 같은 내용으로 함께 갱신한다. 사람용 문서가 사실·ID·구조의 1차 원천이다.
