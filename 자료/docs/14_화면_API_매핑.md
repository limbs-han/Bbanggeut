# Flutter 화면–API 매핑

> 기준: `docs/wireframes/index.html`, `api/openapi.yaml`. 실제 Flutter 구현에서 경로·상태·오류 처리를 변경하면 두 파일을 함께 갱신한다.

## 1. 기본 화면 매핑

| 화면 | 사용자 동작 | API | 주요 성공 상태 | 필수 오류 상태 | 주 담당 |
| --- | --- | --- | --- | --- | --- |
| 로그인 | 회원가입 | `POST /api/auth/signup` | 계정 생성 | 이메일 중복, 입력 오류 | 김수원·박찬형 |
| 로그인 | 로그인 | `POST /api/auth/login` | 토큰 발급 | 자격 증명 오류, 시도 제한 | 김수원·박찬형 |
| 공통 | 토큰 재발급·로그아웃 | `POST /api/auth/refresh`, `POST /api/auth/logout` | 세션 유지·종료 | 만료·폐기 토큰 | 김수원·박찬형 |
| 기기 등록 | 화면 등록 코드 입력 | `POST /api/devices/claim` | `OWNER` 등록 | 등록 모드 꺼짐, 코드 오류·만료·재사용, 이미 등록됨, 실패 5회/10분 초과 | 김수원·박찬형·유지호 |
| 홈 | 내 기기 조회 | `GET /api/devices` | 등록·공유받은 기기와 기기별 역할 목록 | 내 기기 없음, 권한 없음 | 김수원·박찬형 |
| 홈 | 기기 상태 조회 | `GET /api/devices/{deviceId}/status` | 온라인·최근 접속 | 오프라인, 기기 없음 | 김수원·박찬형·유지호 |
| 대시보드·갤러리 | 저장 영상 그리드 | `GET /api/videos?deviceId={deviceId}` | 썸네일 그리드, 기간·감지 유형 필터 | 빈 목록, 멤버십 없음 | 서유정·박찬형 |
| 대시보드·캘린더 | 일자별 영상 조회 | `GET /api/videos?deviceId={deviceId}&from={inclusive}&to={exclusive}` | 일자별 영상 유무·개수, 날짜 선택 시 해당일 목록 | 빈 달, 잘못된 기간, 멤버십 없음 | 서유정·박찬형 |
| 대시보드·통계 | 저장 영상 집계 | `GET /api/devices/{deviceId}/stats?from=&to=&timeZone=` | READY 영상의 감지 유형별 건수·기간별 추이·최다 요일/시간대 | 데이터 없음, 366일 초과, 멤버십 없음 | 김수원·박찬형 |
| 영상 목록 | 목록·기기 필터 | `GET /api/videos?deviceId={deviceId}` | 해당 기기의 페이지 목록 | 빈 목록, 기기 멤버십 없음, 네트워크 오류 | 서유정·박찬형 |
| 영상 상세 | 영상 상세 | `GET /api/videos/{videoId}` | 메타데이터 | 처리 중, 삭제됨, `DeviceMembership` 없음 | 서유정·박찬형 |
| 영상 상세 | 재생 URL | `POST /api/videos/{videoId}/play-url` | 짧은 서명 URL | URL 만료, 권한 회수 | 서유정·박찬형 |
| 영상 상세 | 다운로드 URL | `POST /api/videos/{videoId}/download-url` | 다운로드 시작 | 저장 권한 거부, 만료 | 서유정·박찬형 |
| 영상 관리 | 이름·즐겨찾기 변경 | `PATCH /api/videos/{videoId}` | 변경 반영 | 입력 오류, 권한 없음 | 서유정·박찬형 |
| 영상 관리 | 삭제 | `DELETE /api/videos/{videoId}` | 삭제 작업 접수 | 중복 삭제, 권한 없음 | 서유정·박찬형 |
| 영상 편집 | 원본 다운로드 준비 | `POST /api/videos/{videoId}/download-url` | 짧은 다운로드 URL | 권한 없음, 원본 준비 안 됨 | 서유정·박찬형 |
| 영상 편집 | 로컬 편집·내보내기 | 서버 API 없음 | 단말 파일 또는 공유 결과 | 잘못된 구간, 단말 저장공간·인코딩 오류 | 서유정 |
| 라이브 | 시청 세션 시작 | `POST /api/devices/{deviceId}/stream-sessions` | `PENDING`; `lastActivityAt=createdAt`, `viewerExpiresAt=+45초`, stop deadline=`+60초` | 첫 heartbeat 없음→EXPIRED, 미가입 기기 `404`, `FAILED` | 김수원·박찬형·유지호 |
| 라이브 | 상태·재생 URL 조회 | `GET /api/stream-sessions/{sessionId}` | `PENDING/READY/CLOSED/EXPIRED/FAILED`, `READY`일 때 짧은 HLS URL | 종료·만료·시작 실패 | 김수원·박찬형 |
| 라이브 | 시청 heartbeat | `POST /api/stream-sessions/{sessionId}/heartbeat` | 앱이 15초마다 전송, `204`; active TTL 45초 | 만료·종료 세션 `404` | 김수원·박찬형 |
| 라이브 | 정상 시청 종료 | `DELETE /api/stream-sessions/{sessionId}` | `204`, 상태 `CLOSED`; 마지막 유효 heartbeat/DELETE부터 최대 60초 `STOP_STREAM` 예약, 새 세션 시 취소 | 이미 `CLOSED/EXPIRED`, 네트워크 단절 | 김수원·박찬형·유지호 |
| 라이브 | HLS playlist·segment | 미디어 계층 auth/introspection | session owner+`ACTIVE DeviceMembership`+`READY`; 매우 짧은 token 가능 | 다른 소유자, `CLOSED/EXPIRED`, 권한 회수 즉시 차단 | 김수원·박찬형 |
| 기기 구성원 | 기기 구성원 목록 | `GET /api/devices/{deviceId}/members` | 해당 기기의 `OWNER/MEMBER` 목록 | 기기 멤버십 없음 | 서유정·박찬형 |
| 기기 구성원 | 초대 링크 생성·회수 | `POST/DELETE /api/devices/{deviceId}/invite-link` | OWNER가 회전 가능한 링크 발급 | MEMBER 요청, 회수·만료 | 서유정·박찬형 |
| 기기 초대 신청 | 초대 링크로 가입 요청 | `POST /api/join-requests` | OWNER 승인 대기 요청 생성 | 무효·만료 링크, 중복 요청 | 서유정·박찬형 |
| 기기 구성원 | 가입 요청 승인·거절 | `GET /api/devices/{deviceId}/join-requests`, `POST .../{requestId}/approve|reject` | MEMBER 추가 또는 요청 종결 | 권한 없음, 이미 처리됨 | 서유정·박찬형 |
| 기기 구성원 | 권한 회수 | `DELETE /api/devices/{deviceId}/members/{membershipId}` | 해당 기기 접근 즉시 차단 | 마지막 OWNER 제거, 권한 없음 | 서유정·박찬형 |
| 설정 | 기기 접근 기록 | `GET /api/devices/{deviceId}/access-logs` | 해당 기기 감사 로그 | MEMBER 제한, 페이지 오류 | 김수원·박찬형 |
| 설정 | 기기 관리 | `GET/PATCH/DELETE /api/devices/{deviceId}` | 변경·등록 해제 | 권한 없음, 온라인 작업 중 | 김수원·박찬형·유지호 |

## 2. IoT 전용 API

| 동작 | API | 인증 | 멱등성·실패 처리 |
| --- | --- | --- | --- |
| 화면 등록 코드 발급 | `POST /api/iot/registration-codes` | provisioning된 기기 credential | 120초 코드, 재발급 시 이전 미사용 코드 폐기 |
| 업로드 URL 요청 | `POST /api/iot/videos/upload-url` | 기기 자격 증명 | 이벤트 ID를 멱등 키로 사용 |
| 업로드 완료 통지 | `POST /api/iot/videos/complete` | 기기 자격 증명 | 동일 완료 요청은 영상 1건만 생성 |
| 상태·이벤트 | MQTT 계약 참조 | 기기별 MQTT 계정/인증서 | QoS·ACK·재시도는 `api/mqtt-contract.md` 준수 |

## 3. 공통 앱 처리 규칙

1. 한 사용자는 여러 기기의 `DeviceMembership`을 가질 수 있고 한 기기에도 여러 사용자가 참여할 수 있으므로, 앱은 현재 선택한 기기와 해당 기기에서의 역할을 항상 함께 표시한다.
2. `OWNER/MEMBER`는 기기별 역할이다. 한 기기의 `OWNER` 권한을 다른 기기에 사용할 수 없다.
3. 영상·스트림 요청은 영상이 속한 `deviceId`의 활성 `DeviceMembership`을 서버에서 확인한 뒤 허용한다.
4. `401`이면 토큰 재발급을 한 번 시도하고 실패하면 로그인으로 이동한다.
5. `403`은 현재 기기에서 허용되지 않은 역할 작업 또는 회수 안내를 표시하며 해당 기기의 데이터 캐시를 제거한다.
6. 존재 은닉 정책의 `404`는 `DeviceMembership`이 없는 다른 기기·영상 리소스의 존재 여부를 노출하지 않는다.
7. 서명 URL은 영구 저장하지 않고 만료 시 권한 API로 재발급받는다.
8. 삭제 같은 비동기 작업은 처리 상태를 표시한다. 편집은 앱 로컬 처리이므로 서버 작업 상태를 조회하지 않는다.
9. 오프라인·서버 오류·기기 오프라인을 서로 다른 상태로 보여준다.
10. StreamSession 상태는 `PENDING`, `READY`, `CLOSED`, `EXPIRED`, `FAILED`만 사용한다. 라이브 화면은 시작 시 수초가 걸릴 수 있음을 안내하고 `CLOSED/EXPIRED`를 하나의 종료 화면으로 매핑할 수 있다.
11. 생성 직후 `lastActivityAt=createdAt`, `viewerExpiresAt=createdAt+45초`, 초기 stop deadline=`createdAt+60초`다. 첫 heartbeat가 없는 PENDING도 이 기준으로 회수한다.
12. 앱은 라이브 화면이 `PENDING` 또는 `READY`인 동안 15초마다 heartbeat하고 정상 이탈 시 DELETE를 호출한다.
13. playlist·segment는 session owner+ACTIVE membership+READY를 매 요청 또는 매우 짧은 introspection token으로 확인한다. CLOSED/EXPIRED·권한 회수 후 새 요청은 즉시 차단하며 다른 시청자는 유지한다. 이미 받은 바이트는 회수할 수 없다.
14. 라이브 HLS 자격은 저장 영상 S3 서명 URL과 구분한다. URL을 영구 저장하거나 재사용하지 않는다.
15. 여러 시청자는 기기당 송출 하나를 공유하고 마지막 활동부터 최대 60초 STOP, 활성 중 120초 hardExpiresAt 연장 규칙을 적용한다.
16. 미디어 경로는 Jetson 단일 H.264/AAC 인코더→기기 live publisher→별도 미디어 계층 후보이며 무재인코딩 HLS remux·fan-out한다.
