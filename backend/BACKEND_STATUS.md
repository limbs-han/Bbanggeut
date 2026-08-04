# 백엔드 구현·배포 현황

> 작성 기준: 2026-08-04 (V14 시절 기준이던 이전 판은 git 이력 참고)
>
> 공개 도메인: `https://i15e201.p.ssafy.io`

이 문서는 현재 백엔드에 작성된 코드, EC2에 실제로 배포된 범위, 아직 남은 작업을 구분하기 위한 인수인계 문서다. API 하나하나의 계약은 `자료/api/openapi.yaml`과 `자료/docs/사람이 읽을 문서/04-API명세서.md`가 원본이다.

## 1. 한눈에 보는 현재 상태 (2026-08-04 실측)

| 구분 | 상태 | 비고 |
| --- | --- | --- |
| Spring Boot API | 구현·배포 완료 | loopback 8081, systemd `william-james`. Flyway **V36**까지 |
| PostgreSQL 16 | 배포 완료 | Docker, loopback 전용 |
| Redis 7 | 배포 완료 | 로그인·claim 시도 제한, 기기 presence(90초 TTL) |
| MinIO | 배포 완료 | 영상 버킷 + 편집 버킷(william-james-edit), loopback 전용 |
| Mosquitto MQTT | 배포 완료 | **MQTTS 8883 공개**, TLS + Dynamic Security(기기별 계정·ACL, 익명 차단) |
| MediaMTX | 배포 완료 | **RTSPS 8322 공개**(기기별 계정, publish/read 권한 분리), WHEP 8889 loopback, WebRTC 8189/UDP |
| editor-api (FastAPI) | 배포 완료 | `/editor` 라우트, JWT 검증·금고 권한·presigned 재생, 분석 모델 4개 탑재 |
| Nginx·HTTPS | 배포 완료 | `/api`, `/editor`, WHEP `/webrtc/live`, talkback `/webrtc/talkback` WHIP, live token introspection |
| FCM 푸시 | **운영 활성** | `secrets/app.env`에 `FCM_ENABLED=true` + 서비스 계정 JSON 배치됨. 배포 스크립트는 이 값을 되돌리지 않는다(없을 때만 기본 false 기입) |
| 실제 Jetson/Raspberry Pi 연결 | 코드·프로토콜 준비 완료 | MQTTS·RTSPS 기기 계정 존재. 상시 접속 중인 실기기는 없음(행사·시연 시 연결) |
| 프론트엔드 연동 | 완료 | 인증·기기·영상·라이브(WHEP)·talkback·알림·금고·일정·통계까지 앱이 실제 API 사용 |
| 백업·모니터링 | 배포 완료 | 일일 백업 + 5분 상태 점검 systemd timer |
| CI/CD | 구성 완료 | Jenkins 4스테이지 CI + master CI 성공 시 수동 승인형 production 배포(`wj-deploy-backend`), **editor-api 이미지 빌드·기동 포함** |

## 2. 코드 구성 (도메인 패키지)

위치: `server/src/main/java/com/wj/server/`

| 패키지 | 담당 |
| --- | --- |
| `auth` | 회원가입·로그인·JWT/refresh rotation·비밀번호 변경/재설정·탈퇴·로그인 시도 제한(Redis) |
| `device` | 1회용 등록 코드 claim·소유권 이전·기기 설정·해제, Redis presence |
| `vault` | Memory Vault(금고) — 기기·영상·구성원·구독의 귀속 단위 (V29~V31) |
| `invitation` | 이메일 귀속 초대, 받은 초대함, 수락 알림 |
| `iot` | 기기 credential(BOOTSTRAP→OPERATING), MQTT 수신/명령, `iot.event`의 원시 이벤트·통계(API-46, type 필터) |
| `video`, `storage` | 업로드 URL·완료 확정·재생/다운로드·삭제 워커·보관 만료, 편집 부산물 청소 |
| `stream` | 라이브 세션·WHEP 토큰·introspection·talkback(양방향 오디오, V32)·**유령 세션 대사(MediaMTX 관리 API로 RUNNING 스트림의 실제 미디어 흐름 확인, 연속 2회 미확인 시 실패 처리)** |
| `notification` | 인앱 알림·FCM 푸시(multicast, 무효 토큰 정리)·푸시 토큰·**알림 설정(API-78·79, 새 추억 푸시 게이트)** |
| `schedule` | **캘린더 일정 CRUD(API-74~77, V36)** |
| `editor` | editor-api 서비스 토큰 이벤트 수신(`/api/editor/events` — 분석 완료·댓글 알림 승격) |
| `home`, `subscription`, `audit`, `common` | 홈 요약, 구독(기기·금고), 감사 로그, 공통 오류·rate limit |

### DB 마이그레이션 (Flyway, V36까지)

V1~V14는 이전 판 문서와 동일(사용자·기기·영상·라이브·구독·로그인 제한). 이후:

| 버전 | 내용 |
| --- | --- |
| V15 | 기기 감지 인원 `person_count` |
| V16 | 기기 credential 수명주기(BOOTSTRAP/OPERATING) |
| V17 | 이메일 귀속 초대(공유 링크 폐기) |
| V18~V19 | `device_events` 원시 감지 이벤트 + 인덱스 |
| V20 | 멤버 요청 링크 |
| V21~V25 | 역할 3단계 실험 후 OWNER/MEMBER 2단계 회귀 + 비밀번호 재설정 토큰 + 알림 테이블 |
| V26 | FCM 푸시 토큰 |
| V27~V28 | 시도 이력 인덱스·주단위 파티셔닝 |
| V29~V31 | **Memory Vault** — 금고·기기 바인딩 분리, 초대의 금고 귀속, 레거시 복구 |
| V32 | talkback(양방향 오디오 발화 권한) |
| V33 | 복합 이벤트 타입(CLAP, `videos.event_types` 배열) |
| V34 | 초대 수락 알림 타입 |
| V35 | 편집 알림(분석 완료·댓글) |
| V36 | **일정(user_schedules) + 알림 설정(user_notification_preferences)** |

테스트: `server/src/test/java` 48개+ 클래스. PostgreSQL 통합 테스트는 Docker(Testcontainers) 또는 Jenkins `TEST_POSTGRES_*` 환경에서 실행되고, 없으면 건너뛴다. 최신 스키마 버전은 `FlywayMigrationIntegrationTest`가 고정값으로 검증한다(현재 36).

## 3. EC2 배포 상태

### 3.1 접속과 경로

```text
SSH 사용자: ubuntu
도메인: i15e201.p.ssafy.io
배포 루트: /home/ubuntu/william-james
JAR: /home/ubuntu/william-james/app/server.jar (systemd william-james)
인프라: /home/ubuntu/william-james/infra (docker compose)
편집 모델: /home/ubuntu/william-james/editor-models (Git 미추적)
비밀 환경: /home/ubuntu/william-james/secrets/app.env, infra/.env
```

### 3.2 네트워크 공개 범위

| 포트 | 용도 |
| ---: | --- |
| 22 | SSH |
| 80/443 | HTTPS(API·editor·WHEP·talkback), HTTP는 redirect |
| 8883 | MQTTS(기기 전용, TLS + Dynamic Security) |
| 8322 | RTSPS publish(기기 전용 계정) |
| 8189/UDP | WebRTC 미디어 |
| 8080 | Jenkins |
| 8989 | 기존 Gerrit 관련 서비스 |

Spring(8081)·PostgreSQL·Redis·MinIO·MQTT 1883·RTSP 8554·WHEP 8889는 loopback 전용이다.

### 3.3 배포 방식 (자동화됨)

1. `develop` → `master` 병합 후 master CI(Jenkins) 성공.
2. `/Production/S15P11E201-backend-deploy` 잡에서 **수동 승인**.
3. 승인 시 JAR + `backend-deploy.tar.gz`(compose·mediamtx·mosquitto·nginx 설정 + **editor-api 소스**)를 서버로 보내고 `sudo /usr/local/sbin/wj-deploy-backend`가:
   - editor-api 이미지를 먼저 빌드(실패 시 아무것도 안 바꾸고 중단),
   - 인프라 설정·nginx 교체, 컨테이너 up, editor-api `:previous` 태그 후 교체·헬스체크,
   - JAR 교체·재시작·헬스체크, 실패 시 전체 롤백(이미지 포함).

주의: 배포 wrapper 설치본(`/usr/local/sbin/wj-deploy-backend`)이 릴리스 사본과 다르면 배포가 거부된다. wrapper를 고친 릴리스를 처음 배포할 때는 서버에서 `sudo install -o root -g root -m 0755 ci/jenkins/server/deploy/wj-deploy-backend /usr/local/sbin/wj-deploy-backend`로 설치본을 먼저 갱신한다.

### 3.4 자주 쓰는 확인 명령

```bash
curl https://i15e201.p.ssafy.io/health
curl https://i15e201.p.ssafy.io/editor/health
sudo systemctl status william-james
sudo journalctl -u william-james -f
cd /home/ubuntu/william-james/infra && docker compose ps
sudo ufw status numbered
```

## 4. 남은 작업

- **기념일·주간 리포트 푸시 발송기**: 알림 설정(API-78·79)은 저장·게이트까지 구현됐지만, `anniversaryAlerts`(일정 D-day 푸시)와 `weeklyReport`(주간 집계 푸시)를 실제로 보내는 스케줄러는 없다.
- **실기기 상시 운영**: Jetson/Pi 계정·프로토콜은 준비됐으나 상시 접속 기기가 없다. 연결 시 heartbeat·업로드·라이브 end-to-end 재검증.
- **UFW 정리**: 미사용 8554/tcp 허용 규칙 제거, 8080(Jenkins) 공개 범위 재검토.
- **운영 보강**: off-instance 백업 복제, 외부 알림 채널(모니터 실패 시), 중앙 로그, 부하 테스트.
- **editor-api**: 분석 작업 상태의 프로세스 메모리 의존(재시작 시 진행 중 분석 소실), 작업자 1명 순차 처리, 댓글 표시 이름의 앱 자가 신고(백엔드 프로필 조회 API 필요).
- **secret rotation**: JWT·DB·MinIO 키 정기 교체 절차.

## 5. 절대 저장소에 올리면 안 되는 파일

- `*.pem`, `.env`, `secrets/app.env` 내용
- DB 비밀번호, MinIO access/secret key, JWT signing key, MQTT 비밀번호
- Firebase 서비스 계정 JSON
- 등록 코드 원문, 사용자 access/refresh token
