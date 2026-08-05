# 백엔드 구현·배포 현황

> 작성 기준: 2026-08-04 (V14 시절 기준이던 이전 판은 git 이력 참고)
>
> 공개 도메인: `https://i15e201.p.ssafy.io`

이 문서는 현재 백엔드에 작성된 코드, EC2에 실제로 배포된 범위, 아직 남은 작업을 구분하기 위한 인수인계 문서다. API 하나하나의 계약은 `자료/api/openapi.yaml`과 `자료/docs/사람이 읽을 문서/04-API명세서.md`가 원본이다.

## 1. 한눈에 보는 현재 상태 (2026-08-04 실측)

| 구분 | 상태 | 비고 |
| --- | --- | --- |
| Spring Boot API | 구현·배포 완료 | **무중단 배포 슬롯** — systemd `william-james@8081`/`@8082` 중 하나가 활성(nginx upstream이 지시), loopback 전용. Flyway **V40**까지. 운영 프로파일은 `application-prod.yml`(활성 프로파일 `prod`) — 2026-08-05까지 이름이 `application-demo.yml`이었다. 상세: `deploy/ZERO_DOWNTIME.md` |
| PostgreSQL 16 | 배포 완료 | Docker, loopback 전용 |
| Redis 7 | 배포 완료 | 로그인·claim 시도 제한, 기기 presence(90초 TTL) |
| MinIO | 배포 완료 | 영상 버킷 + 편집 버킷(william-james-edit), loopback 전용. **최소 권한 계정 분리** — 백엔드는 `wj-backend`(영상 버킷만), editor-api는 `wj-editor`(편집 버킷만), root는 관리 전용. 서로의 버킷·admin API는 거부됨(실측 확인) |
| Mosquitto MQTT | 배포 완료 | **MQTTS 8883 공개**, TLS + Dynamic Security(기기별 계정·ACL, 익명 차단) |
| MediaMTX | 배포 완료 | **RTSPS 8322 공개**(기기별 계정, publish/read 권한 분리), WHEP 8889 loopback, WebRTC 8189/UDP |
| editor-api (FastAPI) | 배포 완료 | `/editor` 라우트, JWT 검증·금고 권한·presigned 재생, 분석 모델 4개 탑재 |
| Nginx·HTTPS | 배포 완료 | `/api`, `/editor`, WHEP `/webrtc/live`, talkback `/webrtc/talkback` WHIP, live token introspection |
| FCM 푸시 | **운영 활성** | `secrets/app.env`에 `FCM_ENABLED=true` + 서비스 계정 JSON 배치됨. 배포 스크립트는 이 값을 되돌리지 않는다(없을 때만 기본 false 기입) |
| 실제 Jetson/Raspberry Pi 연결 | 코드·프로토콜 준비 완료 | MQTTS·RTSPS 기기 계정 존재. 상시 접속 중인 실기기는 없음(행사·시연 시 연결) |
| 프론트엔드 연동 | 완료 | 인증·기기·영상·라이브(WHEP)·talkback·알림·금고·일정·통계까지 앱이 실제 API 사용 |
| 백업·모니터링 | 배포 완료 | 일일 백업 + 5분 상태 점검 timer(실패 시 웹훅 알림, `WJ_MONITOR_WEBHOOK_URL`) + **Prometheus/Grafana**(host 네트워크·loopback 전용, `ssh -L 3000:127.0.0.1:3000`으로 조회, 비밀번호는 infra/.env `GRAFANA_ADMIN_PASSWORD`) |
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
| `video`, `storage` | 업로드 URL·완료 확정(크기·sha256·**ETag** 3단 검증)·재생/다운로드·삭제 워커·보관 만료, **편집 완성본(EDIT_OUTPUT 행)과 영상 댓글**(ADR-001로 editor-api에서 이전) |
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
| V37 | 만화 감사 동작 |
| V38 | 기념일·주간 리포트 알림 타입 |
| V39 | **편집 완성본(videos.source_video_id) + 영상 댓글(video_comments)** — ADR-001 |

테스트: `server/src/test/java` 48개+ 클래스. PostgreSQL 통합 테스트는 Docker(Testcontainers) 또는 Jenkins `TEST_POSTGRES_*` 환경에서 실행되고, 없으면 건너뛴다. 최신 스키마 버전은 `FlywayMigrationIntegrationTest`가 고정값으로 검증한다(현재 39). 무중단 배포는 두 슬롯이 겹치는 동안 구 코드가 새 스키마 위에서 돌므로, 마이그레이션은 항상 backward-compatible이어야 한다(`deploy/ZERO_DOWNTIME.md`).

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
   - **대기 슬롯에 새 JAR 기동 → 헬스 확인 → nginx upstream 전환 → 구 슬롯 정지**(다운타임 0, 실측 94,042요청 무실패),
   - 실패 시 upstream을 구 슬롯으로 되돌리고 전체 롤백(이미지 포함).

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

- **실기기 상시 운영**: Jetson/Pi 계정·프로토콜은 준비됐으나 상시 접속 기기가 없다. 연결 시 heartbeat·업로드·라이브 end-to-end 재검증.
- **UFW 정리**: 미사용 8554/tcp 허용 규칙 제거, 8080(Jenkins) 공개 범위 재검토.
- **운영 보강**: off-instance 백업 복제, 중앙 로그. (부하 테스트·무중단 배포는 2026-08-04 완료 — `ci/load/README.md`, `deploy/ZERO_DOWNTIME.md`) 모니터 웹훅은 서버에서 `WJ_MONITOR_WEBHOOK_URL`을 유닛 환경에 넣어야 실제 발송된다(채널 URL은 팀 결정 필요).
- **editor-api**: 분석 작업 상태의 프로세스 메모리 의존(단, 결과는 단계마다 MinIO에 저장되고 상태 조회가 그것으로 `done`을 복원해 자가복구한다), 작업자 1명 순차 처리. 편집 초안 레시피는 아직 editor-api에 남아 있다(ADR-001의 남은 부채).
- **secret rotation**: JWT·DB·MinIO 키 정기 교체 절차.

## 5. 절대 저장소에 올리면 안 되는 파일

- `*.pem`, `.env`, `secrets/app.env` 내용
- DB 비밀번호, MinIO access/secret key, JWT signing key, MQTT 비밀번호
- Firebase 서비스 계정 JSON
- 등록 코드 원문, 사용자 access/refresh token
