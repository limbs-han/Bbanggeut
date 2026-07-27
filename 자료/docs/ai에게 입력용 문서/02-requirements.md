# 요구사항 명세서 (AI/코딩 에이전트용)

> 기준: 5979279 / 2026-07-27 / as-built
> 사람용 원본: [docs/human/02-요구사항명세서.md](../human/02-요구사항명세서.md)

ID 체계: REQ-F-01~42(기능, 42건) + REQ-NF-01~12(비기능, 12건) = 총 54건. FN 참조는 `03-features.md`, API/MQTT 참조는 `04-api-spec.md` 동일 ID 사용.

우선순위(2026-07-27 시연 기준 MVP 확정): **MVP**=시연 7항목(①가입/로그인 F01·02 ②기기등록 F10 ③라이브 F18 ④이벤트영상 확인 F37·21·22 ⑤편집 F27 ⑥다운로드 F26 ⑦통계/리포트 F19·36+F42신규) / **MVP(전제)**=시연 동선 필수 기반(F03 세션, F12 기기목록, F41 탭셸) / **확장**=그 외 전부.
MVP 판정 기준: ⑤⑥은 로컬 편집+기기 저장이면 충족(서버 재업로드 불요). ⑦은 현행 F19·F36으로 충족, F42(전용 리포트 화면)는 신규 개발 항목.

---

## 1. 기능 요구사항 (REQ-F, 42건)

### 1.1 인증

| ID | 요구사항 | 우선순위 | 상태 | 근거 | 관련 FN |
|---|---|---|---|---|---|
| REQ-F-01 | 이메일·비밀번호·표시이름으로 신규 계정 생성 | MVP | ✅ | API-01, `AuthController`/`AuthService` | FN-A03, FN-S01 |
| REQ-F-02 | 이메일·비밀번호 로그인, 5회/10분 실패 시 일시 차단 | MVP | ✅ | API-02, `LoginAttemptService` | FN-A02, FN-S01 |
| REQ-F-03 | 앱 재실행 시 세션 유지, `bbanggeut://` 딥링크 진입 | MVP(전제) | ✅ | `app/app.dart`, `app_controller.dart` | FN-A01 |
| REQ-F-04 | 로그아웃(세션 종료) | 확장 | ✅ | API-04, `auth_sessions` 폐기 | FN-A32, FN-S02 |
| REQ-F-05 | 회원탈퇴(소유 기기 없을 때만) | 확장 | ✅ | API-05, 소유 기기 있으면 409 `OWNER_MEMBERSHIP_EXISTS` | FN-A33, FN-S02 |
| REQ-F-06 | 프로필 표시 이름 수정 | 확장 | ❌ | 프런트 API-06(`PATCH /api/auth/me`) 호출하나 `AuthController.java`에 매핑 없음(grep 0건) | FN-A26, FN-S02 |
| REQ-F-07 | Apple/Google/카카오 간편 로그인 | 확장 | ❌ | 로컬 스낵바만, 프런트·백엔드 모두 없음 | FN-A04 |
| REQ-F-08 | 비밀번호 재설정(찾기) | 확장 | ❌ | 로컬 스낵바만, 양쪽 다 없음 | FN-A05 |
| REQ-F-09 | 로그인 상태에서 비밀번호 변경 | 확장 | ❌ | 로컬 스낵바만, 양쪽 다 없음 | FN-A29 |
| REQ-F-41 | 홈/캘린더/추억/가족/설정 탭 이동, 당겨서 새로고침 | MVP(전제) | ✅ | `main_shell.dart`(`IndexedStack`, `RefreshIndicator`) | FN-A06 |

### 1.2 기기 등록/관리

| ID | 요구사항 | 우선순위 | 상태 | 근거 | 관련 FN |
|---|---|---|---|---|---|
| REQ-F-10 | QR/8자리 코드로 홈캠 기기 등록 | MVP | ✅ | API-08, 코드 TTL 120초·sha256 해시, claim 5회/10분 레이트리밋 | FN-A07, FN-S04, FN-S20, FN-S21, FN-E01, FN-E02 |
| REQ-F-11 | 멤버십 요청 링크 생성·외부 공유 | 확장 | ✅ | API-15/16, 요청자당 활성 링크 1개 | FN-A08, FN-S08 |
| REQ-F-12 | 접근 가능 기기 목록·온라인상태 확인 | MVP(전제) | ✅(부분) | API-07/11, `recording`/`uploadQueueDepth`는 항상 스텁(`false`/`0`) | FN-S03, FN-S05, FN-S25, FN-E03 |
| REQ-F-13 | (OWNER) 기기 이름·보관기간(1~3650일) 변경 | 확장 | ✅ | API-10, 422 `VALIDATION_FAILED` | FN-A27, FN-S05 |
| REQ-F-14 | (OWNER) 기기 소유권 이전 | 확장 | ✅ | API-12 | FN-A24, FN-S06 |
| REQ-F-15 | (OWNER) 기기 계정 해제 | 확장 | ✅ | API-13 | FN-A34, FN-S06 |
| REQ-F-16 | (운영자) 신규 기기 등록, 자격증명 회전/폐기 | 확장 | ✅ | API-47~49, 내부 관리자 키+loopback(`ProvisioningController`); API-49는 호출부 없음(운영자 직접 호출 추정) | FN-S23 |

### 1.3 홈/실시간 시청

| ID | 요구사항 | 우선순위 | 상태 | 근거 | 관련 FN |
|---|---|---|---|---|---|
| REQ-F-17 | 홈 화면 오늘의 통계·최근 하이라이트 | 확장 | ✅ | API-42, `HomeSummaryService` | FN-A09, FN-S19 |
| REQ-F-18 | 요청 시점에만 홈캠 라이브(카드/전체화면) | MVP | ✅ | API-35~38, MQTT-01/04, `stream.py`; `LiveScreen`(FN-A12)은 도달불가지만 `EmbeddedLivePlayer`(FN-A10)로 기능 자체는 구현 | FN-A10, FN-A11, FN-A12, FN-A37, FN-S16, FN-S17, FN-S25, FN-E04, FN-E05 |

### 1.4 캘린더

| ID | 요구사항 | 우선순위 | 상태 | 근거 | 관련 FN |
|---|---|---|---|---|---|
| REQ-F-19 | 월별 캘린더 일자별 영상 개수·목록 | MVP | ✅ | API-27(`from`/`to` 월범위) | FN-A13, FN-S12 |
| REQ-F-20 | 기념일 등록·수정·반복/알림시간 설정 | 확장 | ❌ | `AnniversaryEditorScreen` UI만, 서버 anniversary 코드 0건 | FN-A14 |

### 1.5 영상 관리

| ID | 요구사항 | 우선순위 | 상태 | 근거 | 관련 FN |
|---|---|---|---|---|---|
| REQ-F-21 | 영상 필터링/검색/정렬 목록 | MVP | ✅ | API-27(커서 페이지네이션, size 1~100) | FN-A15, FN-S12 |
| REQ-F-22 | `READY` 저장 영상 재생 | MVP | ✅ | API-31(재생URL TTL 5분), `MediaPlayerSurface` | FN-A17, FN-A37, FN-S14 |
| REQ-F-23 | (OWNER/EDITOR) 제목·메모 수정 | 확장 | ✅ | API-29 | FN-A18, FN-S13 |
| REQ-F-24 | (OWNER/EDITOR) 즐겨찾기 토글 | 확장 | ✅ | API-29(`isFavorite`) | FN-A19, FN-S13 |
| REQ-F-25 | (OWNER) 영상 삭제(비동기 202) | 확장 | ✅ | API-30, `video_deletion_jobs` 큐 워커 | FN-A16, FN-S13 |
| REQ-F-26 | 영상 다운로드 | MVP | ✅ | API-32(`attachment` 디스포지션) | FN-A20, FN-S14 |
| REQ-F-27 | 앱 내 영상 편집(9:16, AI 클립) 후 로컬 저장/공유 | MVP | 🔶 | Banuba 연동은 동작(Android 전용), 서버 재업로드 API 호출 코드 전체 미발견 (⚠️ 미확인) | FN-A21 |

### 1.6 가족 구성원

| ID | 요구사항 | 우선순위 | 상태 | 근거 | 관련 FN |
|---|---|---|---|---|---|
| REQ-F-28 | (OWNER) 이메일+역할로 초대, 목록 확인 | 확장 | ✅ | API-14/18/23 | FN-A22, FN-S07, FN-S10 |
| REQ-F-29 | (OWNER) PENDING 보낸 초대 취소 | 확장 | ✅ | API-19 | FN-A23, FN-S07 |
| REQ-F-30 | (OWNER) 구성원 강제 추방(본인 제외) | 확장 | ✅ | API-24 | FN-A24, FN-S10 |
| REQ-F-31 | 받은 초대 확인·수락/거절 | 확장 | ✅ | API-20~22(만료 시 409 `INVITATION_EXPIRED`) | FN-A25, FN-S09 |

### 1.7 설정

| ID | 요구사항 | 우선순위 | 상태 | 근거 | 관련 FN |
|---|---|---|---|---|---|
| REQ-F-32 | 알림 수신 설정 변경 | 확장 | 🔶 | `flutter_secure_storage` 로컬 저장만, 서버 미반영(테이블/엔드포인트 없음) | FN-A28 |
| REQ-F-33 | (OWNER) 구독(보관 플랜) 조회/활성화/해지 | 확장 | ✅ | API-39~41, 보관 365일/해지 유예 30일 | FN-A30, FN-S18 |
| REQ-F-34 | (OWNER) 접근/조작 기록 조회 | 확장 | ✅ | API-50(커서 페이지네이션) | FN-A31, FN-S24 |

### 1.8 알림/통계

| ID | 요구사항 | 우선순위 | 상태 | 근거 | 관련 FN |
|---|---|---|---|---|---|
| REQ-F-35 | 기념일·받은초대·최근영상 알림 목록 | 확장 | 🔶 | 목록 표시는 됨, "모두 읽음"은 로컬만(알림 테이블 없음) | FN-A35 |
| REQ-F-36 | 기간별 웃음 통계·연간 히트맵 | MVP | ✅ | API-33(`VideoStatsService`); API-46(`EventStatsController`)은 서버 구현되었으나 클라이언트 미사용 | FN-A36, FN-S15, FN-S22 |
| REQ-F-42 | 이벤트 영상 기반 전용 통계/리포트 화면 | MVP | ❌ | **신규 계획 항목(as-built 아님, 개발 예정)** — 시연은 F19·F36으로 대체 가능. 구현/연동 대상 아님에 주의 | 신규(관련: FN-A36, FN-S15) |

### 1.9 이벤트 자동 저장

| ID | 요구사항 | 우선순위 | 상태 | 근거 | 관련 FN |
|---|---|---|---|---|---|
| REQ-F-37 | 웃음 감지 시 자동 클립 촬영/저장 | MVP | ✅ | YAMNet 임계값 0.25/연속2윈도우 → API-25/26, systemd 상시구동 | FN-E06, FN-E07, FN-S11, FN-S25 |

### 1.10 하드웨어/엣지 실험

| ID | 요구사항 | 우선순위 | 상태 | 근거 | 관련 FN |
|---|---|---|---|---|---|
| REQ-F-38 | 팬틸트 자동 추적·프레이밍 | 확장 | ❌ | CAD 완료(FN-H01)이나 `control/framing/target`(MQTT-11) 구독·서보 구동 코드 없음(발행자만). 운영 배포는 MQTT 연결 자체 비활성(`MQTT_HOST=` 빈 값) | FN-E08, FN-H01~H04 |
| REQ-F-39 | 웃음 감지 시 인물/반려동물 정보 동시 기록 | 확장 | 🔶 | `event_fusion_service.py` 코드 완성·로컬검증 확인, 운영 배포는 MQTT 비활성 | FN-E09 |
| REQ-F-40 | 라즈베리파이 기반 카메라 송출 프로토타입 검증 | 확장 | 🔶 | 로컬 MediaMTX RTSP 단순 송출만, 이벤트 로직 없음, 운영과 무관 | FN-E10 |

**합계**: ✅30 / 🔶5 / ❌7 = 42건(REQ-F-01~42 일치). 우선순위 분포: MVP 12(F42 포함) / MVP(전제) 3 / 확장 27.

---

## 2. 비기능 요구사항 (REQ-NF, 12건)

| ID | 분류 | 요구사항 | 근거(설정/코드) |
|---|---|---|---|
| REQ-NF-01 | 보안 | 앱-서버 TLS(nginx+LE), 기기-서버 MQTT TLS(`ssl://`, 커스텀 CA) | `nginx-william-james.conf`(`listen 443 ssl`), `MqttProperties`(`broker-url` 기본 `ssl://localhost:8883`, `tls-ca-path`) |
| REQ-NF-02 | 보안 | JWT HS256 액세스(15분)+리프레시(14일, rotate-on-use) | `config/JwtConfig.java`, `application.yml`(`access-token-ttl`,`refresh-token-ttl`), `auth/application/AuthService.java` |
| REQ-NF-03 | 보안 | 리프레시토큰·등록코드 sha256 해시 저장(평문 미저장) | `auth_sessions.refresh_token_hash`, `registration_codes.code_hash`(둘다 unique) |
| REQ-NF-04 | 보안 | 기기 자격증명 BOOTSTRAP(15분)/OPERATING(30일) 분리, 기기당 1개 | `device-credential.bootstrap-ttl`/`operating-ttl`, `device_credentials` 부분 unique index(V16) |
| REQ-NF-05 | 보안 | 로그인/claim 실패 5회/10분 레이트리밋(이메일·IP 지문) | `LoginAttemptService`/`auth_login_attempts`(V14), `ClaimAttemptService`/`device_claim_attempts` |
| REQ-NF-06 | 프라이버시 | 웃음감지는 엣지 전용(YAMNet), 트리거 시에만 업로드 | `ai/yamnet/yamnet_laughter_detect_jetson.py`(임계값0.25/연속2윈도우), `ai/yolo/laughter_clip_uploader.py` |
| REQ-NF-07 | 프라이버시 | 라이브는 명시적 요청 시만, 유휴60s/뷰어45s/엣지120s 자동중단 | `stream/application/StreamService.java`, `StreamProperties`(`viewer-ttl`,`idle-timeout`,`edge-lease`) |
| REQ-NF-08 | 운영 | PostgreSQL/MinIO 일 03:30 KST 자동 백업, 14일 보관 | `backup-william-james.sh`(`pg_dump -Fc`), `WJ_BACKUP_RETENTION_DAYS:-14`, `william-james-backup.timer` |
| REQ-NF-09 | 운영 | 앱/프록시/컨테이너 상태·디스크 헬스체크 | `management.endpoints.web.exposure.include: health,info,metrics`, `check-william-james.sh`, `william-james-monitor.timer` |
| REQ-NF-10 | 운영 | 테스트→빌드→배포 CI/CD | `.gitlab-ci.yml`(`test-backend`,`test-device-agent`,`package-backend`,`deploy-production`) |
| REQ-NF-11 | 미디어 | H.264+AAC 인코딩 | MQTT `START_STREAM.payload.profile:"LIVE_720P_H264_AAC"`, `stream.py`(ffmpeg) |
| REQ-NF-12 | 미디어 | HLS(m3u8) 스트리밍, 토큰 30초 만료 전 선제 갱신 | `{media-base-url}/{streamId}/index.m3u8?token={liveToken}`, `StreamProperties.live-token-ttl`, `frontend/lib/ui/live_screen.dart`(20초 주기) |

---

## 3. FN 커버리지 검증 (76/76)

앱(37): A01→F03·A02→F02·A03→F01·A04→F07·A05→F08·A06→F41·A07→F10·A08→F11·A09→F17·A10→F18·A11→F18·A12→F18·A13→F19·A14→F20·A15→F21·A16→F25·A17→F22·A18→F23·A19→F24·A20→F26·A21→F27·A22→F28·A23→F29·A24→F14,F30·A25→F31·A26→F06·A27→F13·A28→F32·A29→F09·A30→F33·A31→F34·A32→F04·A33→F05·A34→F15·A35→F35·A36→F36·A37→F18,F22

서버(25): S01→F01,F02·S02→F04,F05,F06·S03→F12·S04→F10·S05→F12,F13·S06→F14,F15·S07→F28,F29·S08→F11·S09→F31·S10→F28,F30·S11→F37·S12→F19,F21·S13→F23,F24,F25·S14→F22,F26·S15→F36·S16→F18·S17→F18·S18→F33·S19→F17·S20→F10·S21→F10·S22→F36·S23→F16·S24→F34·S25→F12,F18,F37

엣지(10): E01→F10·E02→F10·E03→F12·E04→F18·E05→F18·E06→F37·E07→F37·E08→F38·E09→F39·E10→F40

하드웨어(4): H01→F38·H02→F38·H03→F38·H04→F38

**검증 결과**: FN 76개(A37+S25+E10+H04) 전부 REQ-F 중 최소 1개에 연결 확인. ✅ 통과. (F42는 신규 계획 항목 — 대응 FN 없음, 커버리지 무관.)
