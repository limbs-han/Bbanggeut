# 윌리엄 제임스 MQTT 메시지 계약

> 문서 상태: `[기본]` MVP v1  
> 브로커: Mosquitto, MQTT 5.0 권장(MQTT 3.1.1 호환 가능)  
> 영상 파일 전송: MQTT가 아닌 HTTPS + MinIO/S3 단기 서명 URL  
> REST 계약: [`openapi.yaml`](./openapi.yaml)

## 1. 목적과 책임 경계

MQTT는 Jetson/Raspberry Pi와 백엔드 사이의 작은 상태·이벤트·명령 메시지에만 사용한다. MP4, 썸네일, 오디오 원본, 얼굴 이미지, 등록 코드, 토큰, 서명 URL은 MQTT payload에 넣지 않는다.

가장 중요한 원칙은 **로컬 영상 보존이 클라우드 MQTT보다 먼저이며 독립적**이라는 것이다.

```text
웃음·호출어·터치 감지
  ├─ 즉시: 로컬 순환 버퍼 세그먼트 잠금 → MP4 생성 → 로컬 업로드 큐에 영속 저장
  └─ 별도: MQTT 이벤트 발행(상태 알림·관측용, 실패해도 로컬 클립 생성은 계속)

로컬 업로드 워커
  → 네트워크 가능 여부 확인
  → REST 단기 업로드 URL 요청
  → 객체 저장소 직접 PUT
  → REST 완료 통지
```

MQTT 브로커나 백엔드가 중단되어도 기기는 먼저 필요한 영상 구간을 보호하고 로컬 MP4를 만든다. MQTT 이벤트 수신을 영상 생성의 시작 조건으로 사용하지 않는다.

Jetson과 Raspberry Pi가 하나의 카메라 시스템을 이룰 때 서버 권한 단위는 하나의 `deviceId`다. `source.nodeId`로 보드를 구분한다. 사용자 앱은 JWT를 사용하고, 이 계약과 REST IoT 엔드포인트는 기기 전용 자격 증명을 사용한다.

## 2. 공통 규칙

| 항목 | 규칙 |
| --- | --- |
| 토픽 루트 | `{env}/wj/v2`, 예: `dev/wj/v2`, `prod/wj/v2` |
| 인코딩 | UTF-8 JSON, `Content-Type: application/json` |
| 식별자 | 서버 발급 UUID 문자열 |
| 시각 | UTC ISO 8601, 밀리초 포함 권장 |
| 스키마 버전 | 모든 payload에 `schemaVersion: "2.0"` 포함 |
| QoS | heartbeat는 0, 상태·이벤트·명령·ACK는 1 |
| 중복 처리 | `eventId` 또는 `requestId`를 기기 범위 멱등 키로 사용 |
| 순서 | 서로 다른 토픽 사이의 전역 순서를 가정하지 않음 |
| 최대 payload | 64 KiB 이하. 영상·이미지·대용량 로그 금지 |
| 민감정보 | 등록 코드, 사용자 JWT, 기기 토큰, 초대 토큰, 서명 URL 금지 |

알 수 없는 선택 필드는 무시한다. 알 수 없는 major 버전이나 필수 필드 누락은 처리하지 않고 구조화된 오류로 기록한다.

## 3. 연결과 보안

### 3.1 연결

- 운영 환경은 TLS 1.2 이상의 MQTTS를 사용한다. 평문 1883 포트는 외부에 노출하지 않는다.
- `clientId`는 `wj-{deviceId}-{nodeId}` 형식을 권장한다.
- 기기마다 별도 인증서 또는 기기 토큰을 발급한다. 인증서 개인 키나 토큰 원문은 기기 보안 저장소에만 둔다.
- Keep Alive는 30초, 세션 만료는 24시간을 권장한다.
- 재연결은 1, 2, 4, 8초 지수 백오프와 최대 60초 상한·jitter를 적용한다.
- 기기 시간은 NTP로 동기화한다. 오차가 5초를 넘으면 heartbeat에 `clockUnsynced: true`를 표시한다.

### 3.2 ACL

인증된 기기 `deviceId=D`의 최소 ACL은 다음과 같다.

```text
publish:   {env}/wj/v2/devices/D/status
publish:   {env}/wj/v2/devices/D/heartbeat
publish:   {env}/wj/v2/devices/D/registration
publish:   {env}/wj/v2/devices/D/events
publish:   {env}/wj/v2/devices/D/stream/events
publish:   {env}/wj/v2/devices/D/commands/ack
subscribe: {env}/wj/v2/devices/D/commands
```

다른 기기의 토픽과 와일드카드 구독은 금지한다. 백엔드 서비스 계정만 필요한 기기 범위의 와일드카드를 사용할 수 있다.

### 3.3 Last Will

기기 연결 시 아래 LWT를 QoS 1, retained로 설정한다.

```text
{env}/wj/v2/devices/{deviceId}/status
```

```json
{
  "schemaVersion": "2.0",
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "state": "OFFLINE",
  "reason": "CONNECTION_LOST",
  "occurredAt": "2026-07-25T04:05:06.123Z"
}
```

재연결 직후 기기는 같은 토픽에 `ONLINE`을 retained로 발행한다.

## 4. 토픽 요약

| 토픽 suffix | 방향 | QoS | Retain | 용도 |
| --- | --- | :---: | :---: | --- |
| `/status` | 기기 → 서버 | 1 | Y | 온라인·오프라인·오류 상태 전이 |
| `/heartbeat` | 기기 → 서버 | 0 | N | 주기 상태·자원 사용량 |
| `/registration` | 기기 → 서버 | 1 | Y | 물리적 등록 모드 활성·비활성 |
| `/events` | 기기 → 서버·로컬 노드 | 1 | N | 이미 로컬에 보존된 감지·터치 이벤트 통지 |
| `/stream/events` | 기기 → 서버 | 1 | N | 온디맨드 송출 준비·종료·오류 상태 |
| `/commands` | 서버 → 기기 | 1 | N | 스트리밍·설정 갱신 명령 |
| `/commands/ack` | 기기 → 서버 | 1 | N | 명령 수신·처리 결과 |

전체 예시는 `dev/wj/v2/devices/11111111-1111-4111-8111-111111111111/events`다.

## 5. 메시지 상세

### 5.1 기기 상태 `/status`

상태가 변할 때 발행한다.

```json
{
  "schemaVersion": "2.0",
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "state": "ONLINE",
  "reason": "BOOT_COMPLETED",
  "firmwareVersion": "0.4.0",
  "occurredAt": "2026-07-25T04:05:06.123Z"
}
```

| 필드 | 타입 | 필수 | 제약 |
| --- | --- | :---: | --- |
| `schemaVersion` | string | Y | `2.0` |
| `deviceId` | UUID | Y | 인증 주체의 기기 ID와 일치 |
| `state` | enum | Y | `ONLINE`, `OFFLINE`, `DEGRADED`, `ERROR` |
| `reason` | string | Y | 사전 합의한 상태 원인 코드 |
| `firmwareVersion` | string | N | 최대 40자 |
| `occurredAt` | date-time | Y | 기기에서 발생한 시각 |

서버 DB의 MVP 표시 상태는 `DEGRADED`·`ERROR`라도 heartbeat 연결이 유지되면 `ONLINE`으로 저장할 수 있다. 상세 오류는 관측 로그에서 구분한다.

### 5.2 Heartbeat `/heartbeat`

온라인 상태에서 30초마다 발행한다. 네트워크 지연을 고려해 90초 이상 미수신 시 `OFFLINE`으로 판정한다.

```json
{
  "schemaVersion": "2.0",
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "sentAt": "2026-07-25T04:05:30.000Z",
  "uptimeSeconds": 8123,
  "cpuPercent": 34.2,
  "memoryPercent": 61.7,
  "diskFreeBytes": 48103633715,
  "bufferSeconds": 138,
  "recording": true,
  "uploadQueueDepth": 1,
  "personCount": 3,
  "clockUnsynced": false,
  "nodes": [
    {"nodeId": "jetson-main", "online": true},
    {"nodeId": "pi-gateway", "online": true}
  ]
}
```

- 백분율은 `0.0~100.0`, byte·second·count 값은 0 이상의 정수다.
- `recording`은 순환 버퍼가 정상적으로 동작하는지를 의미하며 녹화 표시 LED 상태와 일치해야 한다.
- `uploadQueueDepth`에는 MQTT 성공 여부와 상관없이 로컬에 대기 중인 영상 작업 수가 포함된다.
- `personCount`(선택)는 홈캠 edge가 마지막으로 감지한 화면 내 인원 수(0 이상 정수)다. 인물 탐지·중심 계산은 모두 edge에서 수행하고 서버는 집계값만 저장·전달한다. 필드를 생략하거나 오프라인이 되면 서버는 presence를 `null`로 비운다. 홈 화면의 "가족 N명 감지" 표시에 사용한다.
- 서버는 heartbeat 원문 전체보다 `last_seen_at`과 필요한 최소 상태만 저장해도 된다.

### 5.3 등록 모드 `/registration`

사용자가 기기의 물리 버튼을 길게 누르면 발행한다. 등록 코드 평문은 payload에 넣지 않는다 — 코드는 HTTPS `POST /api/iot/registration-codes`로 발급받아 기기 LCD에만 표시한다.

```json
{
  "schemaVersion": "2.0",
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "mode": "ENABLED",
  "enabledAt": "2026-07-25T04:10:00.000Z",
  "expiresAt": "2026-07-25T04:12:00.000Z",
  "source": {"nodeId": "pi-gateway", "input": "TTP223B_LONG_PRESS"}
}
```

| 규칙 | 내용 |
| --- | --- |
| 지속 시간 | MVP 권장 120초, 서버 허용 최대 5분 |
| `mode` | `ENABLED` 또는 `DISABLED` |
| Retain | Y. 만료 후 기기가 `DISABLED`를 다시 발행 |
| 서버 처리 | 인증된 기기의 `registration_mode_expires_at`만 갱신 |
| Claim 검사 | 등록 코드 해시 역조회로 기기 특정, 코드 120초 TTL·미사용, `UNCLAIMED`, 계정·IP당 실패 5회/10분 제한을 모두 확인하고 성공 시 코드를 사용 처리 |

MQTT 5에서는 retained `ENABLED` 메시지에 Message Expiry Interval을 설정한다. 서버는 브로커 상태를 신뢰하지 않고 payload의 `expiresAt`을 다시 확인한다.

### 5.4 감지·터치 이벤트 `/events`

이 메시지는 서버가 영상을 만들라는 명령이 아니다. 기기가 필요한 세그먼트를 로컬에서 잠그고 업로드 큐에 기록한 후 발행하는 관측·상태 이벤트다.

```json
{
  "schemaVersion": "2.0",
  "eventId": "22222222-2222-4222-8222-222222222222",
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "type": "LAUGHTER",
  "occurredAt": "2026-07-25T04:15:23.450Z",
  "confidence": 0.92,
  "localClip": {
    "state": "QUEUED",
    "beforeMs": 60000,
    "afterMs": 60000,
    "mergeWindowMs": 10000
  },
  "source": {
    "nodeId": "jetson-main",
    "component": "YAMNET",
    "modelVersion": "yamnet-tflite-1"
  }
}
```

| 필드 | 타입 | 필수 | 제약 |
| --- | --- | :---: | --- |
| `eventId` | UUID | Y | 기기가 생성해 영속 저장하는 기기 범위 멱등 키 |
| `deviceId` | UUID | Y | 인증 기기와 일치 |
| `type` | enum | Y | `LAUGHTER`, `WAKE_WORD`, `TOUCH`, `MANUAL` |
| `occurredAt` | date-time | Y | 트리거 실제 발생 시각 |
| `confidence` | number | 조건부 | AI 감지 시 `0.0~1.0`; 터치·수동은 생략 가능 |
| `localClip.state` | enum | Y | `SEGMENTS_LOCKED`, `GENERATING`, `QUEUED`, `FAILED` |
| `localClip.beforeMs` | integer | Y | 이벤트 전 포함 길이 |
| `localClip.afterMs` | integer | Y | 이벤트 후 포함 길이 |
| `localClip.mergeWindowMs` | integer | Y | 반복 웃음을 같은 세션으로 병합하는 시간 |
| `source.nodeId` | string | Y | `jetson-main`, `pi-gateway` 등 |
| `source.component` | enum | Y | `YAMNET`, `KEYWORD_SPOTTING`, `TOUCH_SENSOR`, `APP`, `LOCAL_CONTROL` |
| `source.modelVersion` | string | N | AI 모델 버전 |

MVP 권장 구간:

| 이벤트 | `beforeMs` | `afterMs` |
| --- | ---: | ---: |
| `LAUGHTER` | 60000 | 60000 |
| `WAKE_WORD` | 120000 | 0 |
| `TOUCH` | 120000 | 0 |
| `MANUAL` | 기기 설정값 | 기기 설정값 |

반복 웃음 병합은 최초 `LAUGHTER`의 `eventId`를 영상 `sourceEventId`로 사용한다. 같은 병합 창의 추가 감지는 로컬 세션에 기록하지만 별도 영상을 만들지 않는다.

MQTT 발행 실패 시에도 클립은 로컬 업로드 큐에 남는다. 재연결 후 이벤트를 같은 `eventId`로 재발행할 수 있으며, HTTP 업로드도 같은 `sourceEventId`를 사용한다.

서버는 유효한 `/events` 원문을 `eventId` 기준으로 멱등 저장한다. 이 기록은 영상 행과 별개이므로
클립 생성·업로드에 실패한 감지도 통계와 장애 분석에 남는다. HTTP 업로드가 먼저 도착한 경우에는
동일 UUID `sourceEventId`로 최소 이벤트 행을 복구하고, 이후 영상의 `UPLOADING`·`READY` 상태를 연결한다.
`TOUCH` 이벤트는 `source.component=TOUCH_SENSOR`이고 `confidence`가 없어야 하며, 최초 저장 시
TOUCH는 다른 감지 이벤트와 동일하게 원시 이벤트로만 저장한다. 기기 등록 버튼은
`POST /api/iot/registration-codes`를 호출하는 별도 물리 입력이며 TOUCH 이벤트가 아니다.

### 5.5 서버 명령 `/commands`

```json
{
  "schemaVersion": "2.0",
  "requestId": "33333333-3333-4333-8333-333333333333",
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "type": "START_STREAM",
  "issuedAt": "2026-07-25T04:20:00.000Z",
  "expiresAt": "2026-07-25T04:20:15.000Z",
  "payload": {
    "sessionId": "44444444-4444-4444-8444-444444444444",
    "streamId": "55555555-5555-4555-8555-555555555555",
    "profile": "LIVE_720P_H264_AAC",
    "segmentDurationSeconds": 2,
    "hardExpiresAt": "2026-07-25T04:22:00.000Z"
  }
}
```

| `type` | payload | 단계 | 설명 |
| --- | --- | --- | --- |
| `START_STREAM` | `sessionId`, `streamId`, `profile`, `segmentDurationSeconds`, `hardExpiresAt` | `[기본]` | 활성 송출이 없을 때 미디어 계층으로 보내는 기기 live publisher 하나를 시작 |
| `EXTEND_STREAM` | `streamId`, `hardExpiresAt` | `[기본]` | 활성 시청자가 있을 때 edge 강제 종료 시각 연장 |
| `STOP_STREAM` | `streamId`, `reason` | `[기본]` | 마지막 유효 heartbeat 또는 정상 종료부터 총 60초가 되면 송출 종료 |
| `UPDATE_CONFIG` | `configVersion`, 허용 설정 | `[기본]` | 감지 임계값·병합 창 갱신 |
| `PING` | 빈 객체 | `[기본]` | 명령 경로 진단 |
| `SET_PAN_TILT` | `panDegrees`, `tiltDegrees` | `[심화]` | 수동 카메라 각도 조절. 자동 추적과 동시에 실행하지 않음 |

- 기기는 payload의 `deviceId`가 인증 기기와 같은지, `expiresAt`이 지나지 않았는지 확인한다.
- 알 수 없는 명령은 실행하지 않고 `UNSUPPORTED_COMMAND` ACK를 보낸다.
- 같은 `requestId`는 부작용을 다시 실행하지 않고 저장한 최종 ACK를 재전송한다.
- 명령 payload에 서명 URL·사용자 JWT·기기 토큰을 넣지 않는다.
- 서버 명령은 순환 버퍼와 로컬 이벤트 클립 생성 작업을 중단하거나 지연시키면 안 된다.
- `expiresAt`은 명령 자체의 짧은 실행 기한이고, `payload.hardExpiresAt`은 STOP 명령 유실에 대비한 edge 송출 강제 종료 시각이다.
- `START_STREAM`의 `sessionId`는 최초 시청자 추적용이다. 추가 시청자는 같은 `streamId`를 공유하며 START 명령을 다시 보내지 않는다.

### 5.6 명령 결과 `/commands/ack`

```json
{
  "schemaVersion": "2.0",
  "requestId": "33333333-3333-4333-8333-333333333333",
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "sessionId": "44444444-4444-4444-8444-444444444444",
  "streamId": "55555555-5555-4555-8555-555555555555",
  "status": "SUCCEEDED",
  "errorCode": null,
  "message": null,
  "occurredAt": "2026-07-25T04:20:02.350Z"
}
```

`status`는 `ACCEPTED`, `SUCCEEDED`, `FAILED`, `REJECTED`, `EXPIRED` 중 하나다. `message`에는 토큰·파일 경로·스택 트레이스 등 민감정보를 넣지 않는다.

`START_STREAM` ACK는 최초 시청자를 추적할 `sessionId`와 공유 송출의 `streamId`를 모두 포함한다.
`EXTEND_STREAM`과 `STOP_STREAM` ACK는 `streamId`가 필수이며, 다중 시청 공유 송출에는 대표 시청자 세션이 없으므로
`sessionId`를 생략할 수 있다. 그 밖의 명령에서는 두 필드를 모두 생략할 수 있다.

권장 `errorCode`:

- `INVALID_PAYLOAD`
- `UNSUPPORTED_COMMAND`
- `COMMAND_EXPIRED`
- `DEVICE_BUSY`
- `CAMERA_UNAVAILABLE`
- `STREAM_START_FAILED`
- `CONFIG_VERSION_CONFLICT`
- `PAN_TILT_OUT_OF_RANGE`

### 5.7 온디맨드 송출 상태 `/stream/events`

기기는 live publisher의 준비·종료·오류를 별도 토픽으로 알린다. 이 payload에는 재생 URL을 넣지 않는다.
백엔드는 이 이벤트와 미디어 계층 후보의 playlist 준비 상태를 함께 확인한 뒤 앱 세션을 `READY`로 바꾼다.

```json
{
  "schemaVersion": "2.0",
  "eventId": "66666666-6666-4666-8666-666666666666",
  "requestId": "33333333-3333-4333-8333-333333333333",
  "deviceId": "11111111-1111-4111-8111-111111111111",
  "sessionId": "44444444-4444-4444-8444-444444444444",
  "streamId": "55555555-5555-4555-8555-555555555555",
  "type": "STREAM_READY",
  "occurredAt": "2026-07-25T04:20:03.000Z",
  "hardExpiresAt": "2026-07-25T04:22:00.000Z",
  "errorCode": null
}
```

| 필드 | 필수 | 설명 |
| --- | :---: | --- |
| `eventId` | Y | 기기가 생성한 상태 이벤트 멱등 키 |
| `requestId` | Y | 상태 변화를 만든 START·EXTEND·STOP 명령 ID |
| `deviceId` | Y | 인증 기기와 동일 |
| `sessionId` | 조건부 | 최초 START 요청의 시청자 세션 ID |
| `streamId` | Y | 여러 시청자가 공유하는 edge 송출 ID |
| `type` | Y | `STREAM_STARTING`, `STREAM_READY`, `STREAM_STOPPED`, `STREAM_ERROR`, `STREAM_HARD_EXPIRED` |
| `occurredAt` | Y | 상태 발생 시각 |
| `hardExpiresAt` | Y | edge가 송출을 강제 종료할 시각. 명령 자체의 짧은 `expiresAt`과 구분 |
| `errorCode` | 오류 시 | `ENCODER_UNAVAILABLE`, `PUBLISH_FAILED` 등. HLS remux 오류는 미디어 계층에서 별도로 관측 |

### 5.8 온디맨드 시청 세션 수명 주기

1. 앱이 `POST /api/devices/{deviceId}/stream-sessions`를 호출한다. 서버는 OWNER 또는 MEMBER의 활성 기기 멤버십을 확인한다.
2. 같은 기기의 edge 송출이 이미 `READY`라면 새 **시청자 세션**만 연결하고 MQTT START를 보내지 않는다.
3. 송출이 없다면 서버가 시청자 세션을 `PENDING`으로 만들고 `START_STREAM`을 발행한다. 이때 `createdAt`을 초기 `lastActivityAt`으로 두고 `viewerExpiresAt=createdAt+45초`, 첫 heartbeat가 한 번도 없을 때의 STOP deadline=`createdAt+60초`로 설정한다. HLS 첫 세그먼트가 준비되는 수초 동안 앱은 상태 API를 조회한다.
4. 기기가 `STREAM_READY` 이벤트를 보내고 미디어 계층의 첫 HLS playlist·세그먼트도 준비되면 서버는 같은 `streamId`를 공유하는 대기 시청자 세션을 `READY`로 바꾼다.
5. 앱은 `POST /api/stream-sessions/{sessionId}/heartbeat`를 권장 15초마다 호출한다. 약 45초 동안 heartbeat가 없으면 서버가 비정상 종료 세션을 만료 처리한다.
6. 앱의 정상 종료는 `DELETE /api/stream-sessions/{sessionId}`다. 다른 활성 시청자가 있으면 edge 송출은 유지한다.
7. 마지막 시청 활동 시각(유효 heartbeat 또는 정상 `DELETE`)을 기준으로 60초 idle deadline을 계산한다. heartbeat가 45초 끊긴 세션을 먼저 만료시키되, 그 뒤 60초를 추가로 더하지 않는다. deadline 전에 새 시청자가 오면 예약된 STOP을 취소하고 기존 송출을 재사용한다.
8. 마지막 시청 활동 후 총 60초가 지나면 `STOP_STREAM`을 발행한다. STOP 유실에 대비해 기기는 `payload.hardExpiresAt`에서 스스로 송출을 중단한다.
9. edge hard lease는 MVP 기본 120초다. 활성 시청자가 남아 있으면 서버가 만료 전에 새 `requestId`의 `EXTEND_STREAM`으로 `payload.hardExpiresAt`을 연장한다. 서버나 MQTT가 끊겨도 마지막 연장 시각부터 최대 약 120초 안에 기기가 자체 종료한다.

시청자 세션 TTL 저장은 인메모리, 관계형 DB 등 구현 선택이다. 12일 MVP에서 Redis를 필수 구성 요소로 추가하지 않는다. 어떤 저장 방식을 택하더라도 heartbeat TTL과 정리 작업으로 앱 강제 종료를 회수해야 한다.

### 5.9 순환 녹화와 라이브 인코딩 공유

기기는 카메라·마이크를 H.264/AAC로 **한 번만 인코딩**하고 그 압축 패킷을 순환 버퍼와
온디맨드 live publisher로 나눈다. 별도 미디어 계층 후보가 live publisher의 압축 스트림을 받아 HLS로 remux·fan-out한다.

```text
카메라 + 마이크
  → H.264/AAC 단일 인코더
      ├─ 항상 동작: 순환 버퍼 세그먼트 기록
      └─ 온디맨드: 기기 live publisher
                       → 미디어 계층 후보: HLS remux·fan-out (`-c copy`)
```

- HLS를 위해 기기나 미디어 계층에서 두 번째 H.264 인코더를 실행하지 않는다. 미디어 계층의 HLS 변환은 재인코딩이 아닌 remux이며 FFmpeg 기준 `-c copy`를 전제로 한다.
- HLS 세그먼트를 2초로 잡으면 영상 인코더도 2초마다 IDR 키프레임이 오도록 GOP를 정렬한다. 예를 들어 30fps면 GOP 60, closed GOP를 사용한다.
- 순환 버퍼와 기기 live publisher는 같은 키프레임 정렬 H.264/AAC 출력을 소비하며, 미디어 계층도 이 압축 스트림을 그대로 받는다. 라이브 시작 때문에 순환 버퍼를 재시작하거나 비우지 않는다.
- 첫 IDR과 HLS 세그먼트가 만들어질 때까지 API 상태는 `PENDING`일 수 있다. 앱은 이를 오류로 처리하지 않고 수초간 상태를 갱신한다.
- 입력 형식이 MVP 프로파일과 맞지 않으면 라이브용 즉석 재인코딩으로 우회하지 않고 명확한 오류를 반환한다. 해상도·프레임률·GOP·AAC 설정은 기기 설정에서 미리 고정한다.

## 6. 로컬 클립과 영상 업로드 연계

### 6.1 이벤트 처리 순서

1. 감지 프로세스가 `eventId`를 생성해 로컬 영속 저장소에 기록한다.
2. 순환 버퍼에서 필요한 세그먼트를 즉시 잠근다. 이 단계는 네트워크·MQTT 연결 여부와 무관하다.
3. 반복 웃음 병합 창이 끝나면 FFmpeg로 로컬 MP4를 만든다.
4. MP4 경로, 크기, 전체 파일 SHA-256, 재시도 횟수를 로컬 업로드 큐에 기록하고 fsync 또는 원자적 rename으로 내구성을 확보한다.
5. MQTT `/events`를 발행한다. 실패하면 동일 `eventId`로 재시도하지만 영상 큐 처리는 계속한다.
6. 업로드 워커가 `POST /api/iot/videos/upload-url`에 같은 `eventId`를 `sourceEventId`와 `Idempotency-Key`로 전달한다.
7. 서버가 반환한 단기 URL과 `requiredHeaders`로 객체 저장소에 직접 `PUT`한다.
8. 객체 응답을 확인한 뒤 `POST /api/iot/videos/complete`를 호출한다.
9. 서버가 객체 `HEAD`의 크기와 체크섬 헤더 또는 메타데이터를 검증해 완료를 확정한다.
10. 서버 완료 응답을 로컬에 원자적으로 기록한 뒤에만 보관 정책에 따라 MP4와 잠금 세그먼트를 삭제한다.

### 6.2 업로드 계약

- HTTP 업로드 요청에서 `deviceId`를 입력받지 않는다. 서버가 `DeviceBearerAuth`에서 결정한다.
- 사용자 JWT는 IoT 업로드 엔드포인트에 사용할 수 없으며, 기기 자격 증명도 사용자 앱 API에 사용할 수 없다.
- MVP는 단일 PUT만 지원하며 파일당 최대 500 MiB다. 그보다 큰 파일은 기기에서 재인코딩·분할한 뒤 요청한다.
- URL은 **단기 서명 URL**이다. 일반적인 서명 URL은 만료 전 재사용될 수 있으므로 일회용이라고 가정하지 않는다.
- 요청의 `checksumSha256`은 로컬 MP4 전체 파일의 lowercase hex digest다.
- 응답의 `requiredHeaders`에는 저장소가 지원하는 `x-amz-checksum-sha256` 또는 서명된 `x-amz-meta-sha256`이 포함된다. 기기는 헤더 이름과 값을 변경하지 않는다.
- 완료 API에서 서버는 발급 당시 저장한 기대 크기·SHA-256과 객체 `HEAD` 결과를 비교한다.
- S3 `ETag`는 멀티파트 업로드 등에서 파일 SHA-256이 아니므로 무결성 확인에 사용하지 않는다. `objectETag`를 보내더라도 진단 보조값일 뿐이다.

### 6.3 멱등성과 장애 처리

- 서버는 `(device_id, source_event_id)` 유일 제약으로 같은 영상을 두 번 만들지 않는다.
- 같은 멱등 요청이 이미 완료됐다면 서버는 기존 `videoId`와 `alreadyCompleted=true`를 반환한다.
- URL이 만료됐거나 네트워크가 끊기면 같은 `sourceEventId`로 새 URL을 요청한다.
- 업로드 완료 요청이 유실되면 동일 요청을 재전송한다. 서버가 객체를 다시 `HEAD`해 같은 결과를 반환한다.
- HTTP 4xx 중 인증·형식 오류는 자동 무한 재시도하지 않는다. 429·5xx·네트워크 오류는 지수 백오프로 재시도한다.

## 7. 오프라인·저장 공간 정책

- 이벤트, 잠금 세그먼트, 생성 MP4, 업로드 상태를 SQLite 또는 원자적 파일 저널에 기록한다.
- MQTT QoS 1 이벤트는 PUBACK 전까지 보관하고 재연결 후 같은 `eventId`로 발행한다.
- 저장 공간이 부족하면 **업로드 완료가 서버에서 확인된 가장 오래된 로컬 파일**부터 지운다.
- 아직 서버 완료 확인을 받지 못한 영상을 자동 삭제해야 하는 임계 상황은 LED·LCD로 알리고 구조화된 로컬 오류 로그를 남긴다.
- MQTT가 장기간 중단되어도 HTTPS가 가능하면 업로드 워커는 독립적으로 동작할 수 있다. 반대 상황에서도 로컬 큐를 보존한다.
- 부팅 시 로컬 저널과 파일 시스템을 대조해 `GENERATING`, `UPLOADING` 중단 작업을 복구한다.

## 8. Retain 정책

Retain 허용 토픽은 `/status`, `/registration`뿐이다. `/events`, `/stream/events`, `/commands`, `/commands/ack`, `/heartbeat`는 retain하지 않는다. 이벤트나 명령을 retain하면 재연결한 기기가 오래된 작업을 다시 실행할 수 있다.

기기 초기화·등록 해제 시 retained 상태를 빈 retained 메시지로 지우고 운영 자격 증명을 폐기한다.

## 9. 오류 처리와 관측성

- 서버와 기기 로그는 `eventId`, `requestId`, `deviceId`, `schemaVersion`으로 연결한다.
- payload 전체를 INFO 로그에 남기지 않고 식별자와 상태 코드 중심으로 구조화한다.
- 등록 코드, 사용자 JWT, 기기 토큰, 초대 토큰, 서명 URL, 원본 오디오·영상 경로는 로그에서 마스킹하거나 제외한다.
- 인증 실패, ACL 거부, 반복적인 스키마 오류를 보안 이벤트로 집계한다.
- 처리할 수 없는 기기 이벤트는 허용 필드만 격리 로그에 기록하고 DLQ 또는 로컬 실패 큐로 이동한다.
- 핵심 지표는 온라인 기기 수, heartbeat 지연, 로컬 업로드 큐 깊이, 업로드 성공률, 업로드 소요 시간, 체크섬 불일치 수, 이벤트 중복률이다.

## 10. 계약 테스트 체크리스트

- [ ] 기기 자격 증명으로 다른 `deviceId` 토픽에 publish·subscribe할 수 없다.
- [ ] 비정상 연결 종료 시 LWT `OFFLINE`이 retained로 남는다.
- [ ] 재연결 시 `ONLINE`이 기존 LWT를 덮어쓴다.
- [ ] 등록 모드 만료 후 claim이 거부되고 retained 상태가 `DISABLED`로 바뀐다.
- [ ] MQTT 브로커를 끊어도 이벤트 발생 즉시 로컬 세그먼트가 잠기고 MP4가 생성된다.
- [ ] MQTT 이벤트보다 로컬 업로드 큐 영속 기록이 먼저 완료된다.
- [ ] 같은 `eventId`를 반복 발행·업로드해도 영상 레코드는 하나만 생성된다.
- [ ] 같은 `requestId` 명령을 두 번 받아도 부작용은 한 번만 발생한다.
- [ ] 만료된 명령은 `EXPIRED` ACK를 주고 실행하지 않는다.
- [ ] `/events`, `/stream/events`, `/commands`가 retained로 발행되지 않는다.
- [ ] heartbeat 미수신 90초 뒤 기기가 오프라인으로 표시된다.
- [ ] MQTT payload와 로그에 등록 코드·토큰·서명 URL이 없다.
- [ ] 500 MiB 초과 단일 업로드 URL 요청이 413으로 거부된다.
- [ ] PUT 요청이 응답의 체크섬 헤더 또는 메타데이터를 그대로 포함한다.
- [ ] 완료 API가 객체 `HEAD`의 크기·SHA-256 불일치를 거부한다.
- [ ] S3 `ETag`만 일치하고 SHA-256이 다른 객체가 완료 처리되지 않는다.
- [ ] 네트워크 복구 후 미완료 영상이 동일 `sourceEventId`로 재업로드된다.
- [ ] 최초 시청 세션은 수초간 `PENDING` 후 `STREAM_READY` 이벤트로 `READY`가 된다.
- [ ] 같은 기기의 동시 시청자 2명 이상이 edge 송출 하나와 같은 `streamId`를 공유한다.
- [ ] 앱 heartbeat가 15초 간격으로 갱신되고 약 45초 미수신 세션이 자동 만료된다.
- [ ] 마지막 유효 heartbeat 또는 정상 종료부터 총 60초 안에 새 시청자가 오면 STOP이 취소되고 기존 송출을 재사용한다.
- [ ] heartbeat 중단 시 약 45초에 세션을 만료시키고, 마지막 유효 heartbeat부터 총 60초 시점에 `STOP_STREAM`을 발행한다(45+60초가 아님).
- [ ] STOP 명령이 유실되어도 edge가 `payload.hardExpiresAt`에서 송출을 강제 종료한다.
- [ ] 순환 녹화와 HLS가 H.264/AAC 인코더 하나를 공유하고 HLS는 `-c copy` remux로 생성된다.
- [ ] HLS 세그먼트 길이와 GOP/IDR 간격이 정렬되어 있다.
