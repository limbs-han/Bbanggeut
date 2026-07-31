# 요구사항 명세서 (AI/코딩 에이전트용)

> 기준: to-be 기획(MVP 2026-07-27 확정) · 코드 현황 참조 커밋 5979279
> 사람용 원본: [../사람이 읽을 문서/02-요구사항명세서.md](../사람이%20읽을%20문서/02-요구사항명세서.md)

ID 체계: REQ-F-01~42(기능) + REQ-NF-01~12(비기능) = 54건. FN 참조는 `03-features.md`, API/MQTT 참조는 `04-api-spec.md` 동일 ID 사용. 배치는 MVP 7단계 순서(사람용 원본과 동일 구조). 구현 상태(구현됨/부분구현/미구현)는 본문에 넣지 않고 **부록 B**에만 요약한다.

---

## 1. 기능 요구사항 (REQ-F, 42건)

### 1.1 회원가입 / 로그인

| ID | 요구사항 | 관련 FN | 근거(코드 경로) |
|---|---|---|---|
| REQ-F-01 | 이메일·비밀번호·표시이름으로 신규 계정 생성 | FN-A03, FN-S01 | API-01, `AuthController`/`AuthService` |
| REQ-F-02 | 이메일·비밀번호 로그인, 5회/10분 실패 시 일시 차단 | FN-A02, FN-S01 | API-02, `LoginAttemptService` |
| REQ-F-03 | 앱 재실행 시 세션 유지, `bbanggeut://` 딥링크 진입 | FN-A01 | `app/app.dart`, `app_controller.dart` |
| REQ-F-04 | 로그아웃(세션 종료) | FN-A32, FN-S02 | API-04, `auth_sessions` 폐기 |
| REQ-F-05 | 회원탈퇴(소유 기기 없을 때만) | FN-A33, FN-S02 | API-05, 소유 기기 있으면 409 `OWNER_MEMBERSHIP_EXISTS` |

### 1.2 기기 등록

| ID | 요구사항 | 관련 FN | 근거(코드 경로) |
|---|---|---|---|
| REQ-F-10 | QR/8자리 코드로 홈캠 기기 등록 | FN-A07, FN-S04, FN-S20, FN-S21, FN-E01, FN-E02 | API-08(claim), API-43(코드발급), API-44/45(자격증명); `vaultId` 생략 시 새 금고+OWNER, 지정 시 OWNER 검증 후 기존 금고 binding 생성; 코드 TTL 120초·sha256 해시, claim 5회/10분 레이트리밋 |
| REQ-F-12 | 접근 가능한 금고·기기 목록과 온라인상태 확인 | FN-S03, FN-S05, FN-S25, FN-E03 | Vault API/API-07/11; 금고는 기기가 없어도 반환. MQTT heartbeat 상태는 Redis `presence:device:{id}`에 90초 TTL로 저장되어 목록·상태·금고·라이브 시작 판정에 반영 |
| REQ-F-13 | (OWNER) 기기 이름·보관기간(1~3650일) 변경 | FN-A27, FN-S05 | API-10, 422 `VALIDATION_FAILED` |

### 1.3 홈에서 라이브 스트리밍 시청

| ID | 요구사항 | 관련 FN | 근거(코드 경로) |
|---|---|---|---|
| REQ-F-18 | 요청 시점에만 홈캠 라이브(카드/전체화면) | FN-A10, FN-A11, FN-A37, FN-S16, FN-S17, FN-S25, FN-E04, FN-E05 | API-35~38, MQTT-01/04, `stream.py`; 실사용은 `EmbeddedLivePlayer`(FN-A10). 도달 불가 코드였던 `LiveScreen`(FN-A12, 부록A)은 WebRTC 전용 전환에서 삭제 |
| REQ-F-41 | 홈/캘린더/추억/가족/설정 탭 이동, 당겨서 새로고침 | FN-A06 | `main_shell.dart`(`IndexedStack`, `RefreshIndicator`) |

### 1.4 이벤트(웃음) 감지 영상 확인

| ID | 요구사항 | 관련 FN | 근거(코드 경로) |
|---|---|---|---|
| REQ-F-37 | 웃음 감지 시 자동 클립 촬영/저장 | FN-E06, FN-E07, FN-S11, FN-S25 | YAMNet 임계값 0.25/연속2윈도우 → API-25/26, systemd 상시구동 |
| REQ-F-21 | 저장 영상 필터링/검색/정렬 목록 | FN-A15, FN-S12 | API-27(커서 페이지네이션, size 1~100) |
| REQ-F-22 | `READY` 저장 영상 재생 | FN-A17, FN-A37, FN-S14 | API-31(재생URL TTL 5분), `MediaPlayerSurface` |

### 1.5 영상 편집

| ID | 요구사항 | 관련 FN | 근거(코드 경로) |
|---|---|---|---|
| REQ-F-27 | 폰에서 자르기·비율·효과·자막을 편집하고 온디바이스 음성 인식으로 자동 자막 생성 | FN-A21, FN-A39 | 오디오·전사문 외부 전송 없음. 자동 자막은 수정 가능하며 저장 시 편집 효과와 한 번에 인코딩. 서버 API 불요 |

### 1.6 편집 영상 다운로드

| ID | 요구사항 | 관련 FN | 근거(코드 경로) |
|---|---|---|---|
| REQ-F-26 | 저장된 원본 영상을 기기(단말)로 다운로드 | FN-A20, FN-S14 | API-32(`attachment` 디스포지션) |
| REQ-F-27 (로컬 저장·공유 측면) | 편집 결과를 기기 갤러리에 저장, SNS·메신저 공유 | FN-A21 | 앱 로컬 저장소(`edited_videos/`) 저장 후 공유 시트, 서버 API 불요 |

### 1.7 통계 / 리포트

| ID | 요구사항 | 관련 FN | 근거(코드 경로) |
|---|---|---|---|
| REQ-F-19 | 월별 캘린더 일자별 영상 개수·목록 | FN-A13, FN-S12 | API-27(`from`/`to` 월범위) |
| REQ-F-36 | 기간별 웃음 통계(월평균·전체포착수·주간추이)·연간 히트맵 | FN-A36, FN-S15, FN-S22 | API-33(`VideoStatsService`); API-46(`EventStatsService`)는 서버 구현되었으나 클라이언트 미사용 |
| REQ-F-42 | 이벤트 영상 기반 웃음 리포트. 현재 앱은 로드된 `LAUGHTER` 영상을 날짜별 단말 집계하며 주간/월간·시간대분포·베스트클립 서버 집계는 확장 목표 | FN-A38 **[구현]**, FN-S26 **[제안·미구현]** | `ui/laugh_report_content_screen.dart`; API-62 **[제안·미구현]** |

### 1.8 가족 공유

| ID | 요구사항 | 관련 FN | 근거(코드 경로) |
|---|---|---|---|
| REQ-F-28 | (OWNER) 이메일+역할로 초대, 목록 확인 | FN-A22, FN-S07, FN-S10 | API-14/18/23 |
| REQ-F-29 | (OWNER) PENDING 보낸 초대 취소 | FN-A23, FN-S07 | API-19 |
| REQ-F-30 | (OWNER) 구성원 강제 추방(본인 제외) | FN-A24, FN-S10 | API-24, OWNER 추방불가(409 `OWNER_CANNOT_BE_REVOKED`) |
| REQ-F-31 | 받은 초대 확인·수락/거절 | FN-A25, FN-S09 | API-20~22(만료 시 409 `INVITATION_EXPIRED`) |
| REQ-F-11 | 멤버십 요청 링크 생성·외부 공유(멤버십 자체는 미생성) | FN-A08, FN-S08 | API-15/16, 요청자당 활성 링크 1개; 정식 초대(API-14)가 별도 필요 |

---

## 2. 비기능 요구사항 (REQ-NF, 12건)

| ID | 분류 | 요구사항 | 근거(설정/코드) |
|---|---|---|---|
| REQ-NF-01 | 보안 | 앱-서버 TLS(nginx+LE), 기기-서버 MQTT TLS(`ssl://`, 커스텀 CA) | `nginx-william-james.conf`(`listen 443 ssl`), `MqttProperties`(`broker-url` 기본 `ssl://localhost:8883`, `tls-ca-path`) |
| REQ-NF-02 | 보안 | JWT HS256 액세스(15분)+리프레시(14일, rotate-on-use) | `config/JwtConfig.java`, `application.yml`(`access-token-ttl`,`refresh-token-ttl`), `auth/application/AuthService.java` |
| REQ-NF-03 | 보안 | 리프레시토큰·등록코드 sha256 해시 저장(평문 미저장) | `auth_sessions.refresh_token_hash`, `registration_codes.code_hash`(둘다 unique) |
| REQ-NF-04 | 보안 | 기기 자격증명 BOOTSTRAP(15분)/OPERATING(30일) 분리, 기기당 1개 | `device-credential.bootstrap-ttl`/`operating-ttl`, `device_credentials` 부분 unique index |
| REQ-NF-05 | 보안 | 로그인/claim 실패는 Redis 슬라이딩 윈도우에서 계정·IP 지문 기준 5회/10분 레이트리밋. 성공 예약은 IP 버킷에서 제거하며, 실패 해시는 PostgreSQL 감사 이력으로 별도 보관 | `SlidingWindowRateLimiter`, `LoginAttemptService`/`auth_login_attempts`, `ClaimAttemptService`/`device_claim_attempts` |
| REQ-NF-06 | 프라이버시 | 웃음감지는 엣지 전용(YAMNet), 트리거 시에만 업로드 | `ai/yamnet/yamnet_laughter_detect_jetson.py`(임계값0.25/연속2윈도우), `ai/yolo/laughter_clip_uploader.py` |
| REQ-NF-07 | 프라이버시 | 라이브는 명시적 요청 시만, 유휴60s/뷰어45s/엣지120s 자동중단 | `stream/application/StreamService.java`, `StreamProperties`(`viewer-ttl`,`idle-timeout`,`edge-lease`) |
| REQ-NF-08 | 운영 | PostgreSQL/MinIO 일 03:30 KST 자동 백업, 14일 보관 | `backup-william-james.sh`(`pg_dump -Fc`), `WJ_BACKUP_RETENTION_DAYS:-14`, `william-james-backup.timer` |
| REQ-NF-09 | 운영 | 앱/프록시/컨테이너 상태·디스크 헬스체크 | `management.endpoints.web.exposure.include: health,info,metrics`, `check-william-james.sh`, `william-james-monitor.timer` |
| REQ-NF-10 | 운영 | 테스트→빌드→배포 CI/CD | `.gitlab-ci.yml`(`test-backend`,`test-device-agent`,`package-backend`,`deploy-production`) |
| REQ-NF-11 | 미디어 | 실시간 송출 H.264+Opus 인코딩 | MQTT `START_STREAM.payload.profile:"LIVE_720P_H264_OPUS"`, `stream.py`(ffmpeg) |
| REQ-NF-12 | 미디어 | 운영 WHEP/WebRTC 전용 재생. video/audio track과 inbound audio RTP를 모두 확인하며 실패 시 HLS 폴백 없이 오류·재시도 표시 | `StreamSessionResponse.whepUrl`, `WhepPlayerController`, `live_screen.dart` |

---

## 부록 A: 확장 요구사항

MVP 7단계·가족공유 밖이지만 문서·기능 자체는 유지하는 항목이다. `F06, F07, F20`은 현재 프런트 UI만 있고 서버가 없는 **미구현 스텁**이다. `F08, F09, F35`는 **서버 API가 구현 완료**되었고 앱 연동만 남아 있다.

| ID | 요구사항 | 관련 FN | 비고(코드 경로) |
|---|---|---|---|
| REQ-F-06 | 프로필 표시 이름 수정 | FN-A26, FN-S02 | 향후 확장(스텁) — 프런트가 API-06(`PATCH /api/auth/me`) 호출하나 `AuthController.java`에 매핑 없음(grep 0건) |
| REQ-F-07 | Apple/Google/카카오 간편 로그인 | FN-A04 | 향후 확장(스텁) — 로컬 스낵바만, 프런트·백엔드 모두 없음(`auth_screen.dart:284-298`) |
| REQ-F-08 | 비밀번호 재설정(찾기) | FN-A05 | **서버 구현 완료(API-56, 57)** — 토큰 30분·1회용, 재설정 시 전 세션 폐기. 앱은 미연동(`auth_screen.dart:249-256` 로컬 스낵바) |
| REQ-F-09 | 로그인 상태에서 비밀번호 변경 | FN-A29 | **서버 구현 완료(API-55)** — 현재 비밀번호 확인 후 변경, 현재 세션만 유지. 앱은 미연동(`settings_screen.dart:271-274` 로컬 스낵바) |
| REQ-F-14 | (OWNER) 기기 소유권 이전 | FN-A24, FN-S06 | 확장 — API-12, 이전대상 ACTIVE 멤버 필요(409 `ALREADY_OWNER`) |
| REQ-F-15 | (OWNER) 금고에서 물리 기기 연결 해제 | FN-A34, FN-S06 | API-13은 활성 `device_bindings`만 종료. 금고·영상·구독·금고 멤버십은 보존 |
| REQ-F-16 | (운영자) 신규 기기 등록, 자격증명 회전/폐기 | FN-S23 | 확장/운영 프로비저닝 — API-47~49, 내부 관리자 키+loopback(`ProvisioningController`) |
| REQ-F-17 | 홈 화면 오늘의 통계·최근 하이라이트 | FN-A09, FN-S19 | 확장 — API-42, `HomeSummaryService` |
| REQ-F-20 | 기념일 등록·수정·반복/알림시간 설정 | FN-A14 | 향후 확장(스텁) — `AnniversaryEditorScreen` UI만, 서버 anniversary 코드 0건 |
| REQ-F-23 | (OWNER/MEMBER) 제목·메모 수정 | FN-A18, FN-S13 | 확장 — API-29 |
| REQ-F-24 | (OWNER/MEMBER) 즐겨찾기 토글 | FN-A19, FN-S13 | 확장 — API-29(`isFavorite`) |
| REQ-F-25 | (OWNER) 영상 삭제(비동기) | FN-A16, FN-S13 | 확장 — API-30, `video_deletion_jobs` 큐 워커 |
| REQ-F-32 | 알림 수신 여부 설정 변경 | FN-A28 | 확장 — `flutter_secure_storage` 로컬 저장만, 서버 미반영(테이블/엔드포인트 없음) |
| REQ-F-33 | (OWNER) 구독(보관 플랜) 조회/활성화/해지 | FN-A30, FN-S18 | 확장 — API-39~41, 보관 365일/해지 유예 30일 |
| REQ-F-34 | (OWNER) 접근/조작 기록 조회 | FN-A31, FN-S24 | 확장 — API-50(커서 페이지네이션) |
| REQ-F-35 | 받은초대·웃음영상 준비완료 알림 목록 | FN-A35 | **서버 구현 완료(API-58~61)** — `notifications` 테이블 + dedupe_key 멱등성. 앱은 미연동("모두 읽음"이 아직 로컬만) |
| REQ-F-38 | 팬틸트 자동 추적·프레이밍 | FN-E08, FN-H01~H04 | 향후 확장(범위 외) — CAD 완료(FN-H01)이나 서보 구동 코드 없음(발행자만, MQTT-11 구독자 전무). 운영 배포는 MQTT 연결 자체 비활성(`MQTT_HOST=` 빈 값) |
| REQ-F-39 | 웃음 감지 시 인물/반려동물 정보 동시 기록 | FN-E09 | 향후 확장(범위 외) — `event_fusion_service.py` 코드 완성·로컬검증 확인, 운영 배포는 MQTT 비활성 |
| REQ-F-40 | 라즈베리파이 기반 카메라 송출 프로토타입 검증 | FN-E10 | 향후 확장 — 로컬 MediaMTX RTSP 단순 송출만, 이벤트 로직 없음, 운영과 무관 |

---

## 부록 B: 현재 구현 현황

MVP 7단계 관련 REQ만 간추린 구현 현황이다.

| ID | 상태 | 비고 |
|---|---|---|
| REQ-F-01 | 구현됨 | API-01 |
| REQ-F-02 | 구현됨 | API-02, 로그인 실패 5회/10분 차단 |
| REQ-F-03 | 구현됨 | 세션 유지 + 초대 딥링크 |
| REQ-F-04 | 구현됨 | API-04 |
| REQ-F-05 | 구현됨 | API-05(소유 기기 있으면 거부) |
| REQ-F-10 | 구현됨 | API-08, 코드 TTL 120초 + claim 레이트리밋 |
| REQ-F-12 | 구현됨 | Redis TTL 기반 ONLINE/OFFLINE 및 heartbeat telemetry를 API-07/11·금고·라이브 판정에 반영 |
| REQ-F-13 | 구현됨 | API-10 |
| REQ-F-18 | 구현됨 | API-35~38, MQTT-01/04. `EmbeddedLivePlayer`로 구현됨(미사용 `LiveScreen`은 삭제) |
| REQ-F-41 | 구현됨 | `main_shell.dart` |
| REQ-F-37 | 구현됨 | YAMNet 임계값 판정 → presigned 업로드, systemd 상시 구동 |
| REQ-F-21 | 구현됨 | API-27 커서 페이지네이션 |
| REQ-F-22 | 구현됨 | API-31, 재생 URL TTL 5분 |
| REQ-F-27 | 구현됨 | 로컬 편집·온디바이스 자동 자막·기기 저장 동작. 서버 API 불요 |
| REQ-F-26 | 구현됨 | API-32(다운로드 URL) |
| REQ-F-19 | 구현됨 | API-27(월 범위 조회) |
| REQ-F-36 | 구현됨 | API-33. 별도 이벤트 전용 통계 API(API-46)는 구현돼 있으나 클라이언트 미사용 |
| REQ-F-42 | 부분 구현 | FN-A38 Flutter 단말 집계 화면 구현. FN-S26/API-62 서버 집계는 제안·미구현 |

**ID 검증**: 본문(1.1~1.8절) 고유 REQ-F ID = 01,02,03,04,05,10,12,13,18,41,37,21,22,27,26,19,36,42,28,29,30,31,11 = 23개(REQ-F-27은 1.5·1.6절에 중복 표기되나 동일 ID). 부록 A 고유 REQ-F ID = 06,07,08,09,14,15,16,17,20,23,24,25,32,33,34,35,38,39,40 = 19개. 23+19=42, REQ-F-01~42 전수 반영(결번 없음, 중복 없음). REQ-NF-01~12 전부 2절에 존재(12개). FN 79개·API 51개(06 제외)·MQTT 15개는 각각 `03-features.md`, `04-api-spec.md`에서 확인.
