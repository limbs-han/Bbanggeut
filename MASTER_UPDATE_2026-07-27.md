# 2026-07-27 `master` 통합 변경사항

## 1. 문서 범위

- 기준 브랜치: `master`
- 변경 전 기준: `f066223`
- 현재 기준: `b59043b`
- 통합 커밋: `269c1b2`
- 집계: 162개 파일, 14,743줄 추가, 1,769줄 삭제
- 포함 범위: 영상 편집기, 이메일 초대 및 권한 분리, 기기 이벤트 저장, 업로드 복구, Raspberry Pi 등록 버튼, Edge AI 개선, CI 및 운영 배포

이 문서는 커밋 작성일이 아니라 **오늘 `master`에 실제로 합쳐진 최종 코드**를 기준으로 작성했다. 따라서 며칠 전에 각 기능 브랜치에서 작성된 커밋도 오늘 통합분에 포함된다.

단, 기기 등록 버튼은 오늘 추가됐지만 이 기능이 사용하는 Mosquitto Dynamic Security와 기기 프로비저닝 기반은 오늘 이전의 `master`에 먼저 반영돼 있었다. 기기 등록 흐름을 빠짐없이 설명하기 위해 해당 선행 변경도 이 문서의 **연관 기반 변경**으로 함께 정리한다. 오늘 순수 diff와 선행 기반 변경은 각 절에서 구분한다.

## 2. 핵심 변경 요약

| 직무 | 핵심 변경 |
| --- | --- |
| 프론트엔드·Android | Banuba 영상 편집기 연동, 로컬 편집 화면 개편, 이메일 초대함 및 멤버 관리 UI, `OWNER/EDITOR/VIEWER` 권한별 UI 분기, 앱 아이콘·스플래시 개선 |
| 백엔드 | 이메일 기반 앱 내 초대, 멤버 요청 링크, 3단계 기기 권한, MQTT 감지 이벤트 영속화 및 통계 API, 영상 업로드 실패 복구, Mosquitto 기기 계정 생명주기 보강 |
| AI·Jetson | YAMNet 웃음 감지 평가 도구, 이벤트 전후 영상 생성·업로드, 영구 실패 차단, YOLO·YAMNet 검증 및 운영 스크립트 강화 |
| IoT·Raspberry Pi | GPIO 물리 버튼으로 기기 등록 코드 발급, bootstrap→운영 자격증명 자동 등록, systemd 서비스 설치, 중복 입력·타임아웃 방어 |
| DevOps·QA | Device Agent 테스트 CI 추가, 백엔드 전체 테스트 및 Flyway V23 검증, 운영 서버 수동 배포 및 헬스체크 |

## 3. 프론트엔드·Android

### 3.1 Banuba 영상 편집기

- Flutter에서 Banuba Video Editor V2를 실행하는 어댑터를 추가했다.
- 서버에서 받은 원본 영상을 임시 디렉터리에 내려받은 뒤 편집기로 전달한다.
- 편집 결과는 앱 문서 디렉터리의 `edited_videos`에 H.264 MP4로 저장한다.
- 편집 영상과 함께 커버 이미지 및 편집 메타데이터를 보존할 수 있다.
- 편집 취소, SDK 초기화 실패, 라이선스 오류, 내보내기 실패를 사용자 메시지로 변환한다.
- 초안 저장 및 초안 다시 열기를 지원한다.
- 기본 출력은 HD 720p이며 설정에 따라 자동 해상도 및 HEVC를 사용할 수 있다.

지원 편집 기능:

- 자르기, 분할, 구간 삭제, 클립 연결 및 순서 변경
- 속도, 화면 비율, 전환 효과, 미리보기
- LUT, 시각 효과, 이미지·텍스트·GIF 레이어
- 로컬 음악, 보이스오버, 음성 효과
- 커버 선택 및 초안 저장
- Banuba AI Captions 및 AI Clipping 연동 지점
- 가로 원본을 세로 `9:16` 캔버스에 잘리지 않도록 `scale-to-fit` 배치

운영 시 필요한 값:

- `BANUBA_LICENSE_TOKEN`
- 선택: `GIPHY_API_KEY`
- 선택: `BANUBA_CAPTIONS_API_KEY`, `BANUBA_CAPTIONS_API_V2_KEY`
- 선택: `BANUBA_AI_AUDIO_DATA_URL`, `BANUBA_AI_AUDIO_TRACKS_URL`
- 선택: `BANUBA_EXPORT_QUALITY`, `BANUBA_USE_HEVC`

현재 편집 결과는 **앱 로컬 저장소에 저장**된다. 편집 결과물을 서버 영상 목록으로 다시 업로드하는 기능은 이번 통합 범위에 포함되지 않았다.

### 3.2 이메일 초대 및 가족 관리 화면

- 소유자가 이메일 주소를 입력하고 `EDITOR` 또는 `VIEWER` 역할로 초대할 수 있다.
- 초대받은 사용자는 앱의 받은 초대함에서 초대를 확인하고 수락 또는 거절한다.
- 소유자는 기기의 대기 중 초대 목록을 조회하고 초대를 취소할 수 있다.
- 구성원 목록, 권한 표시, 구성원 접근 권한 회수 UI를 추가했다.
- 앱 링크로 들어온 멤버 요청을 별도 화면에서 처리한다.

중요한 현재 동작:

- 이메일 주소는 초대 대상 계정을 식별하고 수락 권한을 제한하는 용도다.
- SMTP, Gmail, 외부 메일 발송 서비스는 연결하지 않았다.
- 따라서 초대 알림과 수락·거절은 현재 **앱 내부에서 처리**한다.

### 3.3 권한별 화면 분기

- 기기 모델의 `myRole` 기본값을 `VIEWER`로 변경했다.
- `OWNER`와 `EDITOR`에게 영상 편집·메타데이터 수정 UI를 노출한다.
- 영상 삭제, 멤버 관리, 소유권 이전 같은 관리 기능은 `OWNER`에게만 노출한다.
- `VIEWER`는 영상 조회 중심의 읽기 전용 역할로 처리한다.

### 3.4 앱 공통 UI

- 로그인·회원가입 화면과 기기 등록 화면을 개편했다.
- 초대함 진입 경로를 메인 셸에 추가했다.
- 앱 아이콘, 로고, Android 스플래시 화면과 다크 모드 스타일을 수정했다.
- Android Manifest에 딥링크 및 편집 SDK 관련 설정을 반영했다.
- 기기 관리 및 주요 위젯 테스트를 보강했다.

### 3.5 기기 등록·영상 재생·설정 화면 안정화

- 기기 등록 화면에서 뒤로가기 버튼을 누르면 QR 스캐너를 먼저 중지하고 로그인 화면으로 빠져나가도록 수정했다.
- 기기 등록 화면에 명시적인 로그아웃 버튼을 추가했다.
- 서버 로그아웃 요청이 실패하더라도 로컬 토큰과 화면 상태는 항상 초기화하도록 변경했다.
- 사용자 표시 이름 수정 API와 설정 화면을 연결하고 수정된 프로필을 로컬 세션에 다시 저장한다.
- 영상 상세와 미디어 재생 화면의 설정 및 레이아웃을 정리했다.
- 기기 등록 화면의 로그아웃·이탈 동작을 테스트에 추가했다.

이 변경은 사용자가 등록 도중 실패했을 때 등록 화면에 갇히거나 이전 인증 상태가 남는 문제를 줄이는 **앱 측 복구 개선**이다. Mosquitto 계정 생성 실패를 직접 고치는 변경은 아니며, 브로커 및 프로비저닝 개선은 아래 4.7과 6.3에 정리한다.

## 4. 백엔드

### 4.1 이메일 기반 앱 내 초대

기존의 공유 가능한 기기 초대 링크와 가입 요청 모델을 제거하고, 특정 이메일 계정에 귀속되는 초대 모델로 교체했다.

주요 규칙:

- `OWNER`만 초대를 만들고 취소할 수 있다.
- 역할은 `EDITOR` 또는 `VIEWER`만 지정할 수 있다.
- 초대 이메일과 로그인 계정 이메일이 일치해야 수락할 수 있다.
- 같은 기기와 이메일 조합에는 하나의 대기 중 초대만 존재할 수 있다.
- 초대 상태는 `PENDING`, `ACCEPTED`, `DECLINED`, `EXPIRED`, `REVOKED`로 관리한다.
- 기기 등록 해제 시 남은 대기 초대도 정리한다.

관련 API:

| 메서드 | 경로 | 기능 |
| --- | --- | --- |
| `POST` | `/api/devices/{deviceId}/invitations` | 이메일로 `EDITOR` 또는 `VIEWER` 초대 |
| `GET` | `/api/devices/{deviceId}/invitations` | 기기의 대기 초대 조회 |
| `DELETE` | `/api/devices/{deviceId}/invitations/{invitationId}` | 대기 초대 취소 |
| `GET` | `/api/invitations` | 내 받은 초대함 조회 |
| `POST` | `/api/invitations/{invitationId}/accept` | 초대 수락 |
| `POST` | `/api/invitations/{invitationId}/decline` | 초대 거절 |
| `GET` | `/api/devices/{deviceId}/members` | 기기 구성원 조회 |
| `DELETE` | `/api/devices/{deviceId}/members/{membershipId}` | 구성원 권한 회수 |

### 4.2 멤버 요청 링크

직접 이메일 초대 외에, 사용자가 자신의 멤버 요청 링크를 소유자에게 전달하는 보조 흐름을 추가했다.

- 로그인한 사용자가 1회성 멤버 요청 링크를 생성한다.
- 소유자는 링크를 열어 요청자의 계정과 이메일을 확인한다.
- 소유자가 역할을 골라 초대를 생성하면 해당 링크는 사용 처리된다.
- 링크 원문 대신 SHA-256 해시를 DB에 저장한다.
- Android 딥링크 `bbanggeut://membership-request/{token}`으로 앱 화면에 연결한다.

관련 API:

| 메서드 | 경로 | 기능 |
| --- | --- | --- |
| `POST` | `/api/membership-request-links` | 내 멤버 요청 링크 생성 |
| `GET` | `/api/membership-request-links/{token}` | 요청자 미리보기 |
| `GET` | `/api/membership-request-links/{token}/open` | 앱 딥링크로 이동 |

### 4.3 `OWNER/EDITOR/VIEWER` 역할 분리

기존 `OWNER/MEMBER` 구조를 다음 세 역할로 분리했다.

| 기능 | OWNER | EDITOR | VIEWER |
| --- | :---: | :---: | :---: |
| 기기·영상 조회 | O | O | O |
| 영상 제목·설명·즐겨찾기 수정 | O | O | X |
| 로컬 영상 편집 UI | O | O | X |
| 영상 삭제 | O | X | X |
| 이메일 초대·취소 | O | X | X |
| 구성원 권한 회수 | O | X | X |
| 접근 감사 로그 조회 | O | X | X |
| 기기 구독 관리 | O | X | X |
| 소유권 이전 | O | X | X |

마이그레이션 정책:

- 기존 `MEMBER`는 권한 보존을 위해 `EDITOR`로 변환한다.
- 새 초대 및 새 일반 멤버십의 기본 역할은 `VIEWER`다.
- 소유권을 이전하면 대상 `EDITOR` 또는 `VIEWER`가 새 `OWNER`가 된다.
- 이전 소유자는 `EDITOR`가 된다.
- 기기마다 활성 `OWNER`는 한 명만 유지한다.

### 4.4 MQTT 감지 이벤트 저장 및 통계

영상 업로드 성공 여부와 별개로 Edge 감지 원문을 `device_events`에 저장하도록 변경했다.

- 지원 이벤트: `LAUGHTER`, `WAKE_WORD`, `TOUCH`, `MANUAL`
- `eventId`를 기준으로 멱등 저장한다.
- 감지 시각, 신뢰도, 로컬 클립 상태, 전후 구간 길이, 병합 윈도우, 노드·컴포넌트·모델 버전을 보존한다.
- 미래 시각, 잘못된 신뢰도, 잘못된 소스 컴포넌트 및 클립 상태를 검증한다.
- `TOUCH`는 `TOUCH_SENSOR` 소스이며 신뢰도를 갖지 않도록 제한한다.
- AI 이벤트는 신뢰도 값이 필수다.
- HTTP 영상 업로드가 MQTT 이벤트보다 먼저 오면 `sourceEventId`로 최소 이벤트 행을 복구한다.
- 업로드 영상이 준비되면 원시 이벤트와 영상 레코드를 연결한다.

통계 API:

```text
GET /api/devices/{deviceId}/event-stats
```

- 기간, 일자별 이벤트 수, 유형별 이벤트 수, 준비된 업로드 수를 반환한다.
- 기본 조회 기간은 최근 30일이다.
- `timeZone`을 지정할 수 있고 기본값은 `Asia/Seoul`이다.

### 4.5 영상 업로드 복구

- `UPLOADING` 상태에서 완료 통지가 오지 않는 예약을 주기적으로 탐색한다.
- 기본 30분이 지난 업로드를 `FAILED`로 전환한다.
- 같은 이벤트가 다시 요청되면 새 업로드 URL을 발급할 수 있게 했다.
- 스위프 기본 주기는 60초이며 한 번에 최대 100건을 처리한다.
- 오래된 업로드 및 이벤트-영상 연결 조회용 DB 인덱스를 추가했다.

설정값:

```text
UPLOAD_STALE_AFTER=30m
UPLOAD_SWEEP_DELAY_MS=60000
```

### 4.6 기기 생명주기 안정화

- 아직 MQTT 동적 보안 클라이언트가 없는 기기를 해제할 때 불필요한 비활성화 명령을 보내지 않는다.
- 기기 등록 해제, 소유권 이전, 초대 정리 흐름을 새 역할 및 초대 모델에 맞게 보강했다.
- 영상 수정·삭제 권한 검사를 서비스 계층에서 강제한다.

### 4.7 Mosquitto Dynamic Security 및 기기별 MQTT 계정

> 구분: Dynamic Security 전환과 TLS 연결 수정은 오늘 이전 `master`에 반영된 **등록 버튼의 선행 기반**이다. 오늘 통합분에서는 존재하지 않는 MQTT 클라이언트를 해제할 때 오류를 내지 않도록 한 보강이 추가됐다.

기존 공유 MQTT 사용자와 정적 `password_file` 중심 구성을 Mosquitto Dynamic Security 기반으로 변경했다.

- Mosquitto 외부 포트를 평문 `1883`에서 TLS `8883`으로 변경했다.
- TLS 1.2 이상과 서버 인증서, CA, 서버 키를 사용한다.
- 익명 접속을 차단한다.
- `dynamic-security.json`을 영속 볼륨에 저장한다.
- 백엔드는 `$CONTROL/dynamic-security/v1` 요청·응답 토픽으로 기기 계정을 관리한다.
- 각 기기의 MQTT username과 client ID는 기기 UUID다.
- 각 기기마다 `device-{deviceId}` 역할을 생성한다.
- 모든 기기가 하나의 공유 비밀번호를 쓰지 않고, 운영 bearer token을 해당 기기의 MQTT 비밀번호로 사용한다.

기기별 ACL:

| 방향 | 허용 토픽 |
| --- | --- |
| 기기 → 서버 | `status`, `heartbeat`, `registration`, `events`, `stream/events`, `commands/ack` |
| 서버 → 기기 | `commands` |

백엔드 관리자 계정은 전체 기기 명령 토픽 `+/wj/v1/devices/+/commands`에 발행할 수 있다.

Mosquitto 초기화 및 등록 실패 방어:

- Mosquitto 제어 CLI가 TLS 인증서의 hostname과 일치하도록 `localhost` 대신 `MQTT_TLS_HOST`를 사용한다. 운영 기본값은 `i15e201.p.ssafy.io`다.
- 역할 존재 확인을 단일 역할 조회 대신 `listRoles` 결과로 검사한다.
- 과거의 부분 초기화로 `wj-backend` 역할만 남고 관리자 계정 연결이 빠진 경우를 복구하기 위해 `addClientRole`을 항상 재시도한다.
- 브로커가 준비되어 `listClients`에 응답할 때까지 기다린 뒤 역할과 ACL을 구성한다.
- 기기 MQTT 계정 생성 중 일부 명령이 실패하면 생성된 client와 role을 정리한다.
- 자격증명 갱신 시 MQTT client가 사라져 있으면 수정 명령만 보내지 않고 client와 ACL을 새로 만든다.
- 기기 해제 시 MQTT client가 이미 없으면 성공으로 간주해 등록 해제 전체가 실패하지 않도록 했다.
- Dynamic Security 응답이 없거나 명령이 거절되면 `MQTT_IDENTITY_SERVICE_UNAVAILABLE` 또는 `MQTT_IDENTITY_UPDATE_FAILED`로 명확히 실패시킨다.

이 변경은 “DB에는 기기가 생겼지만 Mosquitto 계정·역할이 없어서 연결할 수 없는 상태”, “TLS hostname 불일치로 초기화 명령이 실패하는 상태”, “역할은 있으나 백엔드 계정에 할당되지 않은 부분 초기화 상태”를 방어한다.

## 5. AI·Jetson

### 5.1 Edge 미디어 파이프라인

- 로컬 MediaMTX 설정과 실행 스크립트를 추가했다.
- 공용 RTSP 입력에서 영상·음성 소스를 분리해 AI와 녹화가 함께 사용할 수 있게 했다.
- 1분 단위 로컬 녹화와 저장 용량 기반 정리 타이머를 추가했다.
- 이벤트 전후 구간을 합쳐 MP4 클립으로 만드는 실행 경로를 추가했다.
- Edge AI 녹화, MediaMTX, 로컬 녹화, 정리 작업을 systemd 서비스로 구성했다.

### 5.2 YAMNet 웃음 감지

- FFmpeg 기반 RTSP 오디오 스트림 입력기를 추가했다.
- 웃음 점수 계산 로직과 테스트를 분리했다.
- 운영 후보 임곗값, 연속 감지 횟수, gain, cooldown 설정을 보강했다.
- 실제 녹화 구간에서 평가 데이터셋을 생성하는 CLI를 추가했다.
- MPEG-TS에서 MP4·16kHz mono WAV·파형·메타데이터를 생성할 수 있다.
- 평가 샘플 카탈로그를 JSON, CSV, Markdown으로 관리할 수 있다.
- 현재 테스트 장치에서 확인된 웃음 false negative와 후속 모델 보정 필요 사항을 문서화했다.

### 5.3 YOLO 및 이벤트 영상 업로드

- 스트림 캡처, 이벤트 융합, 자동 프레이밍 및 검증 스크립트를 보강했다.
- 이벤트 클립 업로더에 재시도 정책을 추가했다.
- `408`, `425`, `429`, `5xx`는 백오프로 재시도한다.
- `409`를 포함한 영구적 `4xx`는 반복 재시도하지 않는다.
- 영구 실패 시 `<eventId>.upload-blocked.json` 마커를 남겨 재시작 루프를 방지한다.
- 실패 시 원본 MP4와 트리거 데이터를 보존해 재처리할 수 있게 했다.
- 로그 URL에서 query와 fragment를 제거해 인증정보 노출을 줄였다.
- 응답 본문 로그 길이를 제한했다.
- YOLO·YAMNet 릴리스 검증 및 단위 테스트 범위를 확대했다.

### 5.4 MQTT 버전 구분

- Python Paho MQTT 클라이언트는 `CallbackAPIVersion.VERSION2` 콜백 API를 사용한다.
- 이는 **Paho 콜백 인터페이스 v2**를 뜻한다.
- 서비스 MQTT 토픽 계약 자체는 현재 `prod/wj/v1/devices/{deviceId}/...` 형식을 유지한다.
- 따라서 토픽을 `wj/v2`로 바꾸는 작업은 이번 통합에 포함되지 않았다.

## 6. IoT·Raspberry Pi

### 6.1 물리 등록 버튼

- Raspberry Pi의 BCM GPIO 17과 GND 사이에 연결한 버튼을 감시한다.
- 버튼을 누르면 기기의 운영 토큰으로 `POST /api/iot/registration-codes`를 호출한다.
- 서버가 발급한 2분 유효 등록 코드와 만료 시각을 서비스 로그에 출력한다.
- 버튼 디바운스는 0.2초다.
- 등록 요청이 실행 중이면 추가 버튼 입력을 무시한다.
- 기본 30초가 지나면 요청을 타임아웃 처리한다.
- GPIO 번호와 타임아웃은 환경변수로 변경할 수 있다.

설정값:

```text
REGISTRATION_BUTTON_GPIO=17
REGISTRATION_BUTTON_TIMEOUT_SECONDS=30
```

### 6.2 설치 및 서비스화

- `python3-gpiozero`, `python3-lgpio` 설치를 Pi 준비 스크립트에 포함했다.
- `wj-registration-button.service`를 추가하고 부팅 시 자동 시작하도록 했다.
- 설치 종료 시 서비스 활성 상태를 검사한다.
- 환경 파일 전체를 셸에서 `source`하지 않고 필요한 `API_BASE_URL`만 안전하게 읽는다.
- 설정값 파싱 및 오류 조건 단위 테스트를 추가했다.

현재 코드는 등록 코드를 콘솔 또는 별도 디스플레이에 직접 표시하지 않는다. 코드는 `journalctl -u wj-registration-button`에서 확인하거나, 이후 LCD·LED·앱 전달 방식을 추가해야 한다.

### 6.3 전체 기기 등록 흐름과 기존 실패 개선

기기 등록은 한 번의 앱 코드 입력만으로 끝나는 작업이 아니라 다음 네 단계로 구성된다.

| 단계 | 주체 | 처리 |
| --- | --- | --- |
| 1. 공장 프로비저닝 | 서버 관리자 | loopback 전용 `POST /internal/admin/devices`로 기기와 1회용 `BOOTSTRAP` token 생성 |
| 2. 기기 enrollment | Pi·Jetson | `POST /api/iot/enrollment`에서 bootstrap token을 `OPERATING` token으로 교환 |
| 3. Mosquitto 계정 생성 | 백엔드 | enrollment 트랜잭션에서 기기 UUID client, 전용 role, topic ACL 생성 |
| 4. 사용자 claim | 기기·Flutter | 기기가 2분짜리 등록 코드를 발급하고 사용자가 앱에서 입력해 `OWNER` 멤버십 획득 |

보안 및 복구 규칙:

- 내부 관리자 프로비저닝 API는 Nginx 외부 경로에 노출하지 않는다.
- bootstrap token은 1회용이며 기본 15분 안에 교환해야 한다.
- token 파일은 mode `600`만 허용하며 enrollment 성공 후 삭제한다.
- 운영 token과 MQTT CA를 `/etc/william-james/device-agent.env` 및 인증서 경로에 저장한다.
- 환경 파일 갱신은 임시 파일 작성 후 원자적으로 교체한다.
- enrollment 뒤 설정과 MQTT 서비스를 검사하고, 성공한 경우에만 사용자 등록 코드를 발급한다.
- Mosquitto 계정 생성이 실패하면 백엔드 DB 트랜잭션도 실패하므로 자격증명만 DB에 남는 상태를 줄인다.
- 기기 등록 코드는 운영 자격증명이 있어야 발급할 수 있다.
- 등록 코드는 2분 동안 유효하며 앱에서 claim한 계정이 최초 `OWNER`가 된다.

코드에서 확인되는 기존 등록 장애 개선점:

- TLS 인증서와 맞지 않는 `localhost` 제어 연결을 운영 hostname 연결로 수정했다.
- Mosquitto 관리자 역할의 부분 초기화 상태를 자동 복구한다.
- 운영 자격증명 갱신 시 사라진 MQTT client를 재생성한다.
- 존재하지 않는 MQTT client를 해제할 때 등록 해제 API가 함께 실패하지 않게 했다.
- Pi 준비, enrollment, CA 설치, 서비스 기동, 등록 코드 발급을 각각 수동 처리하던 과정을 스크립트로 연결했다.
- Flutter 등록 실패 후 로그인 화면으로 돌아갈 수 없거나 로컬 세션이 남는 경로를 수정했다.
- GPIO 버튼은 위 등록 코드 발급 명령을 재사용하므로 별도의 미검증 등록 API를 만들지 않는다.

주의:

- 물리 버튼은 enrollment 자체를 대신하지 않는다. 기기에 유효한 `OPERATING` token과 MQTT CA가 먼저 설치돼 있어야 한다.
- 앱에 입력하는 코드는 사용자 소유권 claim용이며 MQTT 비밀번호가 아니다.
- 현재 서버 토픽 버전은 `wj/v1`이고, Python Paho의 `CallbackAPIVersion.VERSION2`와는 별개다.

## 7. DB·API 계약

### 7.1 Flyway

| 버전 | 변경 |
| --- | --- |
| V17 | 공유 초대 링크·가입 요청 제거, 이메일 귀속 초대 테이블 생성 |
| V18 | 원시 기기 이벤트 및 업로드 상태 저장 |
| V19 | 오래된 업로드 및 이벤트-영상 연결 인덱스 |
| V20 | 1회성 멤버 요청 링크 |
| V21 | 기존 `MEMBER`를 `EDITOR`로 변환 |
| V22 | `VIEWER` 역할 추가 |
| V23 | 새 멤버·초대 기본값을 `VIEWER`로 설정하고 역할 제약 갱신 |

### 7.2 계약 문서

- OpenAPI 문서를 이메일 초대, 멤버 요청 링크, 3단계 권한, 이벤트 통계 API에 맞게 갱신했다.
- MQTT 계약 문서에 원시 이벤트 영속화, 영상과 이벤트 연결, 등록 버튼과 `TOUCH` 이벤트의 구분을 추가했다.
- DB 스키마 문서를 `OWNER/EDITOR/VIEWER` 구조와 V23 기준으로 갱신했다.

## 8. CI·테스트·운영

### 8.1 CI

- GitLab CI에 `test-device-agent` 작업을 추가했다.
- Python 3.12 환경에서 Device Agent 테스트를 실행한다.
- 백엔드 테스트, 패키징, 배포 단계의 기존 구조는 유지한다.
- 현재 배포 job은 자동 실행이 아니라 수동 실행 방식이다.

### 8.2 테스트

보강된 주요 테스트:

- 이메일 초대 생성·수락·거절·취소
- 멤버 요청 링크 생성 및 사용
- `OWNER/EDITOR/VIEWER` 권한
- 소유권 이전
- MQTT 이벤트 유효성 및 멱등 저장
- 영상 이벤트 연결
- 오래된 업로드 실패 전환 및 재시도
- Raspberry Pi 등록 버튼 설정 검증
- bootstrap token 파일 권한, enrollment 응답, 운영 환경 파일 갱신
- bootstrap 교환 시 Mosquitto 기기 identity 생성 호출 및 기기 해제 시 identity 회수 연계
- YAMNet 웃음 평가 데이터셋
- YOLO 스트림 캡처, 이벤트 융합, 클립 업로드 및 결과 요약

### 8.3 운영 서버 반영

- 백엔드 전체 테스트와 `bootJar` 빌드를 통과했다.
- 운영 DB, MinIO 데이터, 기존 JAR을 배포 전에 백업했다.
- Flyway V17~V23이 운영 DB에 적용됐다.
- 최초 배포에서 `EventStatsService` 운영 생성자의 `@Autowired` 누락을 발견했다.
- `b59043b`에서 생성자 주입을 수정하고 `master`에 푸시했다.
- 수정 JAR을 재배포한 뒤 서비스를 정상화했다.
- 최종 확인:
  - `william-james.service`: `active`
  - 외부 `/health`: `{"status":"UP"}`
  - DB 스키마: V23
  - MQTT 구독: 연결 정상

## 9. 직무별 후속 확인사항

### 프론트엔드

- 운영 Banuba 라이선스와 AI Captions·Clipping 설정값 주입
- 실제 Android 기기에서 편집, 초안, 저장 권한 및 대용량 영상 검증
- 편집 결과의 서버 재업로드가 필요하면 별도 API·UX 설계
- 이메일 초대 및 멤버 요청 딥링크 실기기 검증

### 백엔드

- 초대 만료 상태를 정리하는 정책 또는 배치 점검
- 이벤트 통계의 운영 데이터량 증가에 따른 쿼리 성능 관찰
- 이메일 알림이 필요하면 SMTP 또는 메일 서비스 연동을 별도 구현
- `VIEWER` 읽기 권한과 `EDITOR` 수정 권한에 대한 API 통합 테스트 확대

### AI·Jetson

- 최종 Logitech BRIO 100 환경에서 YAMNet 재평가
- 웃음 false negative 개선을 위한 모델·특징·임곗값 재검토
- 실제 claim 완료 기기로 이벤트 영상 업로드 end-to-end 검증
- 운영 서비스 재시작 후 새 릴리스 경로와 설정 반영 확인

### IoT·Raspberry Pi

- 운영 서버에서 새 테스트 기기를 bootstrap→enrollment→Mosquitto client 생성→앱 claim까지 다시 end-to-end 검증
- `mosquitto_ctrl dynsec getClient {deviceId}`로 client·role·ACL 생성 결과 확인
- MQTTS `8883` 연결 시 CA와 hostname 검증 확인
- 실제 GPIO 버튼 배선 및 길게 누르기·연속 누르기 검증
- 발급된 등록 코드를 사용자에게 보여줄 출력 장치 또는 앱 전달 방식 결정
- 버튼 서비스 로그 로테이션과 장애 알림 점검

### DevOps

- 수동 deploy job의 실행 조건과 권한 정리
- 백엔드뿐 아니라 Flutter·AI 릴리스 검증을 CI 단계로 확대
- 배포 후 `/health`, DB 버전, MQTT 연결을 자동 확인하는 smoke test 추가

## 10. 주요 커밋

| 커밋 | 내용 |
| --- | --- |
| `269c1b2` | 백엔드, 영상 편집기, Pi 등록 버튼, AI 변경 통합 |
| `8d3ca47` | 기기 역할을 `OWNER/EDITOR/VIEWER`로 분리 |
| `54c324f` | Edge AI MVP 테스트·웃음 평가·업로드 안전성 강화 |
| `1dd29be` | YAMNet 웃음 점수 분리, RTSP 검증 및 Jetson 릴리스 검사 |
| `8c3427e` | 로컬 MediaMTX·순환 녹화·이벤트 클립 파이프라인과 AI 운영 문서 |
| `158190f` | Banuba 영상 편집 기능 |
| `9f7f909` | Raspberry Pi GPIO 등록 버튼 서비스 |
| `6a9cb04` | 멤버 요청 링크 |
| `856cde4` | 원시 기기 이벤트 저장 및 통계 |
| `c3b3536` | 기기 생명주기 및 영상 업로드 복구 강화 |
| `223af75` | 이메일 귀속 앱 내 초대 백엔드 |
| `a0836db` | 이메일 초대·초대함 프론트엔드 |
| `47fa445` | 기기 등록 이탈·로그아웃 및 영상 재생·설정 화면 안정화 |
| `e885fd7` | Device Agent 테스트 CI |
| `182181d` | 백엔드 구현 및 파트별 연동 현황 문서 |
| `b59043b` | `EventStatsService` 생성자 주입 수정 및 운영 정상화 |

등록 기능의 선행 기반 커밋:

| 커밋 | 내용 |
| --- | --- |
| `8590d1e` | Mosquitto TLS·Dynamic Security, 기기별 MQTT 계정·ACL, 운영 자격증명 |
| `37d497c` | Mosquitto TLS hostname·관리자 역할 복구, Jetson 등록 및 라이브 연결 |
| `69c24e4` | Raspberry Pi 프로비저닝·enrollment·MediaMTX 설치 자동화 |

### 10.1 전수 확인 기준

- `git diff f066223..b59043b`의 162개 변경 파일을 `frontend`, `backend`, `ai`, CI, 계약·DB 문서로 분류했다.
- 위 범위의 비-merge 커밋 15개를 기능 절 또는 주요 커밋 표에 매핑했다.
- merge commit `3bbd655`, `982ed2c`, `269c1b2`는 자체 기능 변경 없이 각각 Pi 등록 버튼, AI, 전체 통합 이력을 연결한다.
- Mosquitto 프로비저닝은 오늘 순수 diff가 아니지만 등록 버튼의 동작 전제이므로 선행 커밋 `8590d1e`, `37d497c`, `69c24e4`까지 별도로 역추적했다.
