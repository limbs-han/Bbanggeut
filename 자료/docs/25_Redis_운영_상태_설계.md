# Redis 운영 상태 적용 설계

## 1. 적용 기준

Redis에는 다음 조건을 만족하는 상태만 둔다.

- 짧은 TTL이 데이터 의미의 핵심이다.
- 같은 행을 자주 갱신해 PostgreSQL 쓰기 부하와 잠금 경합을 만든다.
- 서버 인스턴스가 여러 대여도 원자적으로 공유해야 한다.
- Redis 장애 시 기능을 중단하지 않고 PostgreSQL로 폴백할 수 있다.

사용자·멤버십·초대·기기 바인딩·영상·감사 이력처럼 복구와 트랜잭션 정합성이 필요한 데이터는 PostgreSQL을 원장으로 유지한다.

## 2. 적용한 영역

### 로그인·기기 등록 실패 제한

- 키: `rl:login:*`, `rl:claim:*`
- 자료구조: sorted set 기반 sliding window
- 역할: 계정·IP별 5회/10분 제한을 Lua로 원자 처리
- 성공 처리: 계정 실패 버킷은 초기화하되 공용 IP 버킷에서는 해당 성공 예약만 제거
- 영구 이력: 실제 실패 해시는 PostgreSQL 파티션 테이블에 보안 감사용으로 별도 기록
- 장애 정책: Redis 장애 시 요청은 허용하고 리버스 프록시의 전체 트래픽 제한을 유지

### 기기 presence와 heartbeat telemetry

- 키: `presence:device:{deviceId}`
- TTL: 기본 90초(`DEVICE_PRESENCE_TTL`)
- 값: `lastSeenAt`, `recording`, `uploadQueueDepth`, `bufferSeconds`, `personCount`, `firmwareVersion`
- heartbeat 주기: 30초
- ONLINE 판정: 키가 존재함
- OFFLINE 판정: 키가 없거나 TTL이 만료됨

정상 heartbeat는 Redis 값과 TTL만 갱신한다. 기존처럼 heartbeat마다 `devices` 행을 UPDATE하거나 상태 API 호출 때 stale 행을 OFFLINE으로 UPDATE하지 않는다.

Redis 상태는 다음 경로에 반영한다.

- 기기 목록과 단건 조회
- 기기 상태 API
- 추억 금고에 연결된 기기 상태
- 라이브 스트림 시작 전 ONLINE 검증

여러 기기를 반환하는 목록은 Redis `multiGet`으로 일괄 조회해 N회 왕복을 피한다.

## 3. 장애와 복구

- Redis 쓰기 실패: heartbeat를 기존 PostgreSQL `devices` 행에 기록한다.
- Redis 읽기 실패: DB의 `status`, `last_seen_at`, telemetry 필드로 폴백한다.
- 명시적 ONLINE/OFFLINE MQTT 이벤트: 저빈도 전환이므로 Redis와 PostgreSQL에 함께 반영한다.
- Redis 재시작: 키가 사라져 기기는 일시 OFFLINE으로 보이며, 다음 heartbeat에서 자동 복구된다.
- 잘못된 Redis JSON: 해당 키를 OFFLINE으로 취급하고 경고 로그를 남긴다.

## 4. 검토했지만 PostgreSQL에 유지한 영역

| 영역 | 유지 이유 |
|---|---|
| 인증 세션과 refresh token hash | 로그아웃·비밀번호 변경 즉시 무효화라는 보안 의미가 있어 캐시 삭제 실패나 짧은 stale window도 허용하기 어렵다. 매 요청 캐시는 별도 트랜잭션 outbox/버전 키 설계 후 도입한다. |
| 스트림 세션 상태 전이 | MQTT 명령, 감사 로그, 재시작 복구, 다중 뷰어 정리가 하나의 상태 머신을 이루어 부분 이전 시 이중 원장 문제가 생긴다. |
| 등록 코드·초대·비밀번호 재설정 | 1회 소비와 계정·기기 트랜잭션이 결합되어 있고 서버 재시작 후에도 복구돼야 한다. |
| 영상 삭제 작업·업로드 상태 | 외부 오브젝트 스토리지 작업의 재시도와 중복 방지에 영구 작업 큐가 필요하다. |
| 알림 미읽음 수·홈 통계 | 현재 트래픽 규모에서 원본 변경 지점 전체의 캐시 무효화 복잡도가 조회 절감보다 크다. |

## 5. 설정

```yaml
app:
  device-presence:
    ttl: ${DEVICE_PRESENCE_TTL:90s}
```

heartbeat 주기의 최소 2배 이상으로 설정한다. 현재 30초 주기에서는 기본 90초가 두 번의 일시 누락을 허용한다.
