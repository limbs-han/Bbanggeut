# 백로그 인수인계 — 2026-08-04

백엔드 코드 감사(면접 대비 질문 60개를 코드로 검증)에서 나온 남은 작업을 파트별로
정리했다. **백엔드 단독으로 가능한 것은 이미 다 처리했고**, 여기 남은 것은
① 기기 파트와 합의가 필요한 것, ② 프론트 후속 연동, ③ 보류로 합의된 운영 항목이다.

각 항목은 "지금 코드가 어떻게 되어 있는지"를 파일:라인으로 붙였다. 문서가 아니라
코드를 근거로 쓴 것이므로, 반박할 때도 코드로 반박해 주면 좋겠다.

---

## A. 기기 파트 협의 필요 (우선순위 순)

### A-1. 기기 자격증명의 용도 분리 ⚠️ 보안

**현상 — 토큰 하나가 두 문을 연다.** 프로비저닝이 만드는 자격증명
`keyId.secret` 한 값을 HTTP와 MQTT가 함께 쓴다.

| 쓰임 | 근거 |
| --- | --- |
| HTTP Bearer (업로드 URL 발급·완료 확정·자격증명 회전) | `provision.py:27` — `Authorization: Bearer <token>` |
| MQTT 비밀번호 (heartbeat·라이브 명령) | `agent.py:63` — `username_pw_set(device_id, bearer_token)` |
| 서버가 같은 값을 두 곳에 넣는 지점 | `ProvisioningService.java:110` — `mqttIdentityManager.create(deviceId, credential.bearerToken())` |
| 발급 지점 | `ProvisioningService.java:137~144` — `keyId + "." + secret` |

**왜 고쳐야 하나**

1. **유출 반경이 두 배다.** 침해 경로는 프로토콜마다 다른데(브로커 로그·프록시
   로그·기기 메모리), 어느 한쪽으로 새면 공격자가 **업로드 위조와 라이브 제어를
   동시에** 얻는다.
2. **회전이 전부-또는-전무다.** MQTT만 의심스러워도 바꾸면 HTTP 업로드까지 끊긴다
   (`ProvisioningService.java:112`의 `rotate`가 두 곳을 한꺼번에 갈아버린다).
   업로드 큐가 쌓인 기기는 회전을 미루게 되고, 결국 "의심스러운데 못 바꾸는" 상태가 된다.
3. **저장 강도가 비대칭이다.** 서버 DB는 secret의 SHA-256, Mosquitto는 PBKDF2로
   같은 평문을 보관한다 — 보안 수준이 약한 쪽으로 결정되고, 유출 시 어느 통로가
   뚫렸는지 특정할 수 없다.

**제안** — `device_credentials.purpose`(V16에 이미 있는 컬럼)에 값을 더한다.

- `OPERATING_HTTP` → 업로드 API용 Bearer
- `OPERATING_MQTT` → Mosquitto 계정 비밀번호용
- 프로비저닝 응답이 `{httpToken, mqttPassword}` 두 필드를 반환
- 기기는 `DEVICE_BEARER_TOKEN` / `DEVICE_MQTT_PASSWORD`를 따로 보관

**합의가 필요한 것 (혼자 못 바꾸는 이유)**

- 기기 에이전트(`config.py`·`provision.py`·`agent.py`)가 env 두 개를 읽어야 한다.
- **이미 배포된 기기의 마이그레이션 경로.** 서버만 바꾸면 구 토큰 하나만 가진
  기기가 전부 접속 불가가 된다 → 과도기 동안 서버가 둘 다 받아주는 단계가 필요하다.
- `자료/api/mqtt-contract.md`와 프로비저닝 절차 문서를 함께 갱신해야 한다.

### A-2. bootstrap → operating 교환에 유예·ack가 없다

- 서버는 새 자격증명을 발급하면서 **기존 것을 즉시 폐기**한다
  (`ProvisioningService.java:105~115` — revoke 먼저, 발급 나중).
- 기기 저장 순서 자체는 안전하다(tmp+fsync+원자 교체 후 bootstrap 삭제,
  `provision.py:126~183`). 하지만 **서버로 ack를 보내지 않는다.**
- 결과: HTTP 응답이 유실되거나 기기가 저장 직전에 죽으면 bootstrap은 이미 죽었고
  새 토큰은 없다 → **기기 스스로 복구 불가, 운영자가 수동 재발급**해야 한다.
- 제안: 새 토큰의 첫 사용을 확인할 때까지 구 토큰을 짧게 유예하거나, 같은
  요청을 멱등 재교환으로 만든다.

### A-3. 운영 토큰 자동 회전이 없다

- V16이 만료(수명주기)를 도입했지만 기기가 만료 전에 스스로 갱신하지 않는다.
  회전 API(`rotateSelf`)는 있으니 기기 쪽 스케줄만 붙이면 된다.
- 합의할 것: 만료 며칠 전에 갱신할지, 실패 시 재시도 정책.

### A-4. 웃음 자동 저장을 끌 수 없다 🔴 사생활

**현상 — 세 곳 모두에 없다.** 사용자가 "자동 저장을 멈춰 달라"고 할 방법이 없다.

- 백엔드: `UpdateDeviceRequest`에 필드가 `name`·`retentionDays` **둘뿐**
- 프론트: 설정 화면의 스위치 3개는 **알림 수신** 토글이다(기념일·주간 리포트·새 추억)
  — 즉 "저장은 되고 알림만 끈다"
- 기기 env: 웃음 감지를 끄는 변수가 없다(`YAMNET_CLAP_ENABLED`로 박수만 끌 수 있다)
- 저장소 전체 grep(`autoCapture`/`captureEnabled`/`detectionEnabled`) 히트 0건
- 유일한 우회는 운영자가 서비스를 정지시키는 것

**제안**: `devices.capture_enabled` 컬럼 + `PATCH /api/devices/{id}` 확장 + MQTT로
기기에 전달. **기획 합의가 먼저 필요하다** — 오탐으로 사적인 장면이 저장됐을 때
사용자가 스스로 멈출 수 있어야 한다는 것이 면접·심사에서 지적받기 쉬운 지점이다.

### A-5. heartbeat 스텁 두 개 (서버가 기기 상태를 못 본다)

`agent.py:284~285`가 고정값을 보낸다.

- `uploadQueueDepth: 0` — 실제 업로드 백로그를 서버가 알 수 없다(DB에는 저장된다)
- `clockUnsynced: False` — MQTT 계약(`mqtt-contract.md:56`)은 "오차 5초 초과 시 true"를
  요구하는데 구현이 없다. 서버도 이 필드를 파싱하지 않는다(`MqttInboundHandler`).
- 기기 시계가 틀리면 클립 추출 자체는 어긋나지 않지만(파일명과 이벤트 시각이 같은
  시계에서 나와 오차가 상쇄됨) **서버에 올라가는 `capturedStartAt`이 그만큼 틀려서
  통계·캘린더가 통째로 밀린다.**
- NTP 동기화(chrony 등) 설치·검증이 어떤 install 스크립트에도 없다.

### A-6. 이벤트 디렉터리가 무제한 누적된다

- 녹화 세그먼트는 정리된다(`recording-prune.sh` + 타이머, 보존일수·용량 상한).
- 그런데 **`EVENT_DIR`(~/ai_events)를 정리하는 코드·타이머가 없다.** 클립·트리거
  JSON·업로드 상태·로그가 계속 쌓인다.
- 더 나쁜 것은 **우선순위 역전**이다: 영구 실패한 이벤트 클립(`upload-blocked.json`)이
  오래된 녹화 세그먼트보다 오래 살아남는다.
- 자유 공간 기준 정책도 없다(`df`는 출력용으로만 쓰인다).

### A-7. 박수(CLAP) 감지를 이제 켤 수 있다 ✅ 차단 해제

- 기본값이 `YAMNET_CLAP_ENABLED=false`인 이유는 "백엔드·앱이 `eventTypes`를 지원하기
  전까지"였다(`ADVANCED_AUDIO_EVENTS.md:60`).
- **그 전제는 해소됐다** — V33의 `videos.event_types` 배열과 앱의 이벤트 타입 표시가
  이미 병합돼 있다. 켤지 결정만 하면 된다.

### A-8. 서보 추적을 운영 릴리스로 올리기

- 실기 종단 검증은 끝났지만 "재부팅 시 자동 시작되는 운영 릴리스"는 아니다.
- 남은 12단계 절차가 `llm/handoff/SERVO_OBJECT_TRACKING_HANDOFF_20260729.txt` §7에
  있다(드라이런 → 외부 전원 → 부팅 자동시작 검증 → 새 SG90 재보정 → 30분 내구시험).
- PAN/TILT는 안전 확인 전까지 ±10도로 고정돼 있다.

---

## B. 프론트 후속 연동 (백엔드는 준비 완료)

| 항목 | 서버 상태 | 프론트 상태 |
| --- | --- | --- |
| **금고(가족) 단위 통계 API-80** | `GET /api/vaults/{vaultId}/event-stats` 구현·배포 완료. 기기별 분해(`byDevice`) 포함 | **미연동**(grep 0건). 리포트 화면에서 "기기별 ↔ 가족 전체" 전환을 붙일 수 있다 |
| **새 푸시 타입 2종** | `ANNIVERSARY`(매일 09:00 KST), `WEEKLY_REPORT`(매주 월 09:00 KST) 발송기 구현 완료 | **미처리**(grep 0건). 푸시를 눌렀을 때 캘린더·리포트 화면으로 보내는 라우팅이 없다 |
| 일정 CRUD·알림 설정 | 구현 완료(API-74~79) | 연동 완료 |

## C. 백엔드에 남은 소소한 것

- **업로드 크기 상한 부정합**: 서버 선언은 500 MiB(`IotVideoService.java:58`)인데
  nginx는 2g를 허용한다(`nginx-william-james.conf:73,88`). presigned PUT은 구조상
  크기를 서명에 넣을 수 없어(POST policy만 가능) 실질 상한이 nginx 값이다.
  → nginx를 선언값에 맞추는 편이 맞다.
- **presigned 무결성**: `/complete`가 대조하는 SHA-256은 **기기가 스스로 붙인
  메타데이터**다(MinIO가 본문을 검산하지 않는다). 실제로 강제되는 건 크기뿐이고,
  요청의 `objectETag`는 받기만 하고 쓰이지 않는다.
- **editor-api**: 분석 작업 상태가 프로세스 메모리에 있다(단, 결과는 단계마다
  MinIO에 저장되고 상태 조회가 그것으로 `done`을 복원하므로 시스템은 자가복구한다 —
  우선순위 낮음). 작업자 1명 순차 처리. 댓글 표시 이름이 앱 자가 신고라 백엔드
  프로필 조회 API가 있으면 서버가 박을 수 있다.

## D. 보류 합의 (운영 항목)

팀 논의로 **당장 하지 않기로** 한 것들. 기록만 남긴다.

- off-instance 백업 복제(현재 백업이 같은 EC2 디스크에 있어 인스턴스와 함께 죽는다)
- 중앙 로그(journald 뿐, 인스턴스가 죽으면 사후 분석 불가)
- 모니터 웹훅 URL 연결(코드는 준비됨 — `WJ_MONITOR_WEBHOOK_URL`만 넣으면 동작)
- secret rotation 절차(JWT 서명키 하나가 앱·editor-api·라이브 토큰에 공용)
- UFW 정리(미사용 8554/tcp, 8080 공개 범위)
- 백업 복구 훈련(한 번도 검증 안 됨)

---

## 참고 — 2026-08-04에 백엔드가 처리한 것 (재확인 불필요)

일정 CRUD·알림 설정(API-74~79) / 금고 통계(API-80) / 기념일·주간 리포트 발송기 /
유령 라이브 세션 대사(MediaMTX API) / 관측성(Prometheus·Grafana·모니터 웹훅 코드) /
MinIO 최소 권한 계정 분리 / refresh 토큰 재사용 감지 / 스케줄러 기동 보정 /
editor-api 배포 자동화 / **무중단 배포(blue-green, 전환 중 94,042요청 무실패 실측)** /
k6 부하 테스트(350VU·335rps에서 p95 9ms, 한계 미발견)

코드 감사에서 **이미 잘 방어된 것으로 확인된 항목**(다시 의심할 필요 없음):
업로드 멱등(`ON CONFLICT (device_id, source_event_id)`), stale UPLOADING sweep 워커,
삭제 순서(MinIO→DB, 멱등), 엣지 hard lease 120초, MQTT 명령 중복 멱등,
Redis 장애 시 presence PG 폴백, keyset 커서 페이지네이션, claim 코드 원자 소비,
`pg_advisory_xact_lock` 기기 직렬화, 소유권 이전의 deferred 제약, SQL 인젝션(`#{}` 전용).
