# 백엔드 구현·배포 현황

> 작성 기준: 2026-07-20
>
> 작업 브랜치: `feat/backend-skeleton`
> 공개 도메인: `https://i15e201.p.ssafy.io`

이 문서는 현재 백엔드에 작성된 코드, EC2에 실제로 배포된 범위, 아직 남은 작업을 구분하기 위한 인수인계 문서다.

## 1. 한눈에 보는 현재 상태

| 구분 | 상태 | 비고 |
| --- | --- | --- |
| Spring Boot API | 구현·배포 완료 | Java 17, `127.0.0.1:8080`. 2026-07-20 등록 코드·양도 변경분은 로컬 구현 완료, EC2 재배포 필요 |
| PostgreSQL | 배포 완료 | Docker, EC2는 Flyway V10까지 적용. V11(등록 코드)은 다음 배포 시 자동 적용 |
| MinIO | 배포 완료 | 비공개 영상 버킷 생성, loopback 전용 |
| Mosquitto MQTT | 배포 완료 | 백엔드 연결 정상, loopback 전용 |
| MediaMTX | 기본 설치 완료 | RTSP/HLS loopback 전용 |
| Nginx·HTTPS | 배포 완료 | HTTP→HTTPS, API reverse proxy |
| 실제 Jetson/Raspberry Pi 연결 | 미완료 | MQTTS·미디어 publish 인증 필요 |
| 프론트엔드 연동 | 미완료 | API와 라이브 heartbeat 연동 필요 |
| CI/CD | 미완료 | 현재 JAR 수동 배포 방식 |

2026-07-19 확인 결과 공개 health endpoint는 HTTP 200이며, Spring Boot·Nginx·Docker·기존 Gerrit 서비스는 모두 `active` 상태다.

## 2. 로컬에 구현된 백엔드 코드

백엔드 애플리케이션 위치는 [`server`](./server)다.

### 2.1 인증

위치: [`server/src/main/java/com/wj/server/auth`](./server/src/main/java/com/wj/server/auth)

- 회원가입
- 로그인
- BCrypt 비밀번호 해시
- JWT access token 발급
- refresh token 해시 저장 및 rotation
- 로그아웃 시 소유 세션 회수
- 사용자·세션 상태 검증

### 2.2 기기와 멤버십

위치: [`server/src/main/java/com/wj/server/device`](./server/src/main/java/com/wj/server/device)

- 화면 표시 1회용 등록 코드 기반 기기 claim (2026-07-20, 인쇄식 제품 코드 폐지)
  - 기기가 `POST /api/iot/registration-codes`로 코드를 발급받아 7" LCD에 `XXXX-XXXX` 표시
  - Crockford 32자셋 8자리, 120초 TTL, 1회용, DB에는 SHA-256 해시만 저장
  - 앱은 코드만 제출하고 서버가 해시 역조회로 대상 기기를 특정
  - 입력 정규화: 대문자화·하이픈 제거·혼동 문자 보정(O→0, I/L→1)
- claim 성공 시 OWNER 멤버십 생성
- claim 실패 계정·IP당 5회/10분 제한 (코드는 기기에 귀속되지 않으므로 추측 주체 기준)
- 사용자 기기 목록·상세·상태 조회
- 기기 이름·영상 보존 일수 변경
- 기기 해제·양도: 기존 행 REVOKED 종결 + credential·초대·멤버십 회수 + 영상 삭제 작업 등록 + 같은 시리얼의 새 UNCLAIMED 행 생성
- heartbeat가 오래된 기기의 OFFLINE 판정

### 2.3 초대와 구성원

위치: [`server/src/main/java/com/wj/server/invitation`](./server/src/main/java/com/wj/server/invitation)

- **초대 링크 + 승인 방식** (2026-07-20, 이메일 귀속 초대 폐지)
  - OWNER가 기기별 초대 링크 생성(기본 7일 만료, 재발급 시 이전 링크 무효화, 해시만 저장)
  - 링크를 받은 사용자가 로그인 후 가입 요청(PENDING) 제출 — 링크만으로는 멤버십이 생기지 않음
  - OWNER가 가입 요청 목록을 보고 승인(MEMBER 멤버십 생성·재활성화) 또는 거절
- MEMBER 목록 조회
- MEMBER 권한 회수

전달 채널은 OWNER가 링크를 카톡 등으로 직접 공유하는 방식이라 별도 이메일 발송 연동이 필요 없다.

### 2.4 IoT 인증과 MQTT

위치: [`server/src/main/java/com/wj/server/iot`](./server/src/main/java/com/wj/server/iot)

- 사용자 JWT와 분리된 기기 credential 인증
- MQTT broker 연결과 자동 재접속
- 기기 status·heartbeat·registration 메시지 수신
- recording, buffer, upload queue, firmware 상태 반영
- 라이브 START·EXTEND·STOP 명령 발행
- 라이브 준비·오류·종료 이벤트 수신

MQTT 메시지 계약은 [`../자료/api/mqtt-contract.md`](../자료/api/mqtt-contract.md)에 있다.

### 2.5 영상과 객체 저장소

위치: [`server/src/main/java/com/wj/server/video`](./server/src/main/java/com/wj/server/video), [`server/src/main/java/com/wj/server/storage`](./server/src/main/java/com/wj/server/storage)

- 기기 영상 업로드 URL 발급
- MinIO 직접 PUT 업로드
- 객체 크기·SHA-256 검증 후 업로드 완료 확정
- 영상 목록·상세·재생·다운로드
- 제목·설명·즐겨찾기 변경
- 비동기 영상 삭제 worker
- **보관 만료 스케줄러** (2026-07-20): `retention_until`이 지난 영상을 주기적으로(기본 60초) DELETING 전환 + 삭제 작업 등록. 업로드·편집 완료 시 `retention_until`을 기기 보관 일수(기본 30일, 구독 활성 시 365일) 기준으로 기록
- **기기 구독(멤버십)** (2026-07-20): OWNER가 시작·해지, 결제는 MVP 범위 밖. 활성 시 보관 365일로 연장, 해지 시 즉시 삭제 없이 `max(기본 기준, 해지일+유예 30일)`로 재계산 — 유예 중 재구독하면 복구
- FFmpeg 구간 편집 worker
- 편집 결과를 별도 영상 객체로 생성하고 원본 보존

서버에는 FFmpeg 6.1.1이 설치되어 있다.

### 2.6 라이브 스트리밍 제어

위치: [`server/src/main/java/com/wj/server/stream`](./server/src/main/java/com/wj/server/stream)

- OWNER와 MEMBER의 시청 세션 생성
- 같은 기기의 여러 시청자가 하나의 edge stream 공유
- 최초 요청에만 MQTT START 발행
- 시청자 heartbeat와 TTL 갱신
- 마지막 활동 후 idle timeout에 MQTT STOP 발행
- edge hard lease와 EXTEND 명령
- 시청 세션과 stream ID에 귀속된 단기 HLS 토큰
- Nginx 내부 introspection을 통한 HLS 접근 제어

기본 시간은 다음과 같다.

| 항목 | 값 |
| --- | ---: |
| 시청자 heartbeat 권장 주기 | 15초 |
| 시청자 TTL | 45초 |
| 마지막 활동 후 idle timeout | 60초 |
| edge hard lease | 120초 |
| live token TTL | 30초 |

### 2.7 감사 로그와 공통 오류

위치: [`server/src/main/java/com/wj/server/audit`](./server/src/main/java/com/wj/server/audit), [`server/src/main/java/com/wj/server/common`](./server/src/main/java/com/wj/server/common)

- 기기·멤버십·영상·스트림 주요 작업 감사 로그
- cursor 기반 로그 조회
- 공통 API 예외 응답
- validation 오류 처리
- 요청별 `X-Request-Id` 생성·반환

### 2.8 DB 마이그레이션

위치: [`server/src/main/resources/db/migration`](./server/src/main/resources/db/migration)

| 버전 | 내용 |
| --- | --- |
| V1 | 사용자와 인증 세션 |
| V2 | 기기와 멤버십 |
| V3 | claim 보안과 기기 credential |
| V4 | 영상 |
| V5 | 영상 삭제 작업 |
| V6 | 초대 |
| V7 | 기기 관리 상태 |
| V8 | 감사 로그 |
| V9 | 영상 편집 |
| V10 | 라이브 stream/session |
| V11 | 1회용 등록 코드 테이블, devices 제품 코드 컬럼 제거, 시리얼 부분 유니크(양도 대비) |
| V12 | 초대 링크·가입 요청 테이블(이메일 초대 테이블 제거), 기기 구독 컬럼, retention_until 백필·만료 인덱스 |

기존 단일 `schema.sql` 방식은 제거하고 Flyway로 통일했다.

### 2.9 API 계약과 테스트

- OpenAPI: [`../자료/api/openapi.yaml`](../자료/api/openapi.yaml)
- 테스트 위치: [`server/src/test/java`](./server/src/test/java)
- 테스트 클래스: 20개 (2026-07-20 등록 코드·양도·초대 링크·가입 승인·구독·보관 만료 테스트 포함)
- 로컬 검증 명령: `./gradlew test`

PostgreSQL과 Mosquitto를 사용한 수동 통합 검증에서 다음 흐름을 확인했다.

- Flyway V10 적용
- 회원가입과 JWT 인증
- 영상 편집 요청 생성·조회
- MQTT heartbeat의 기기 상태 반영
- 두 시청자의 동일 stream ID 공유
- MQTT 이벤트에 의한 `PENDING → READY`
- 정상 live token은 204, 다른 stream에 재사용한 토큰은 401
- 시청 heartbeat와 정상 종료는 204

## 3. EC2에 실제 배포된 범위

### 3.1 접속과 경로

```text
SSH 사용자: ubuntu
도메인: i15e201.p.ssafy.io
배포 루트: /home/ubuntu/william-james
JAR: /home/ubuntu/william-james/app/server.jar
인프라: /home/ubuntu/william-james/infra
비밀 환경 파일: /home/ubuntu/william-james/secrets/app.env
```

PEM과 환경변수 실제 값은 저장소에 포함하지 않는다. 서버의 비밀 파일 권한은 600이다.

### 3.2 설치된 구성

- Ubuntu 24.04
- OpenJDK 17
- FFmpeg 6.1.1
- Docker와 Docker Compose
- PostgreSQL 16
- MinIO
- Eclipse Mosquitto
- MediaMTX
- Nginx
- Certbot/Let's Encrypt

배포용 파일은 [`deploy`](./deploy)에 있다.

### 3.3 실행 방식

Spring Boot는 `william-james.service`라는 systemd 서비스로 실행된다.

```bash
sudo systemctl status william-james
sudo journalctl -u william-james -f
sudo systemctl restart william-james
```

PostgreSQL·MinIO·Mosquitto·MediaMTX는 Docker Compose로 실행된다.

```bash
cd /home/ubuntu/william-james/infra
docker compose ps
docker compose logs -f
```

### 3.4 네트워크 공개 범위

UFW에서 허용된 포트는 다음과 같다.

| 포트 | 용도 |
| ---: | --- |
| 22 | SSH |
| 80 | HTTPS redirect와 인증서 갱신 |
| 443 | William James HTTPS API |
| 8989 | 서버에 기존 설치되어 있던 Gerrit 관련 서비스 |

다음 포트는 loopback에만 바인딩되어 외부에서 직접 접근할 수 없다.

| 포트 | 용도 |
| ---: | --- |
| 8080 | Spring Boot |
| 5432 | PostgreSQL |
| 9000·9001 | MinIO API·console |
| 1883 | Mosquitto MQTT |
| 8554 | MediaMTX RTSP ingest |
| 8888 | MediaMTX HLS |

### 3.5 HTTPS와 reverse proxy

- 공개 health: `https://i15e201.p.ssafy.io/health`
- API prefix: `https://i15e201.p.ssafy.io/api`
- HTTP 요청은 HTTPS로 redirect
- 인증 없는 보호 API 요청은 401
- `/live/{streamId}`는 백엔드 token introspection을 통과해야 접근 가능
- `i15e201.p.ssafy.io` 인증서 자동 갱신 timer 활성화

서버에 원래 존재하던 별도 `p.ssafy.io` 수동 인증서는 자동 갱신 dry-run에서 실패하지만, 이번에 발급한 `i15e201.p.ssafy.io` 인증서의 dry-run은 성공했다. 기존 인증서는 임의로 삭제하지 않았다.

### 3.6 배포 방식의 현재 한계

현재 배포는 다음과 같은 수동 방식이다.

```text
로컬에서 test·bootJar
→ SCP로 server.jar 업로드
→ systemctl restart william-james
```

GitLab에 코드를 push해도 EC2가 자동으로 갱신되지는 않는다. CI/CD 구축 전에는 코드 push와 서버 배포를 별도 작업으로 취급해야 한다.

## 4. 남은 작업

### P0: 실제 서비스 연결 전에 반드시 필요

#### 4.1 실제 기기 provisioning

- 출고 기기의 `deviceId`, serial number를 운영 DB에 등록하는 관리자 도구 또는 제한된 배치 필요
- 기기별 REST credential 발급·교체·회수 절차 필요 (등록 코드 발급 API가 기기 credential 인증을 전제로 함)
- 인쇄식 product code는 폐지됨 — 등록 코드는 기기가 등록 모드 진입 시 서버에서 실시간 발급받아 화면에 표시하므로 출고 시 코드 생성·인쇄 절차가 필요 없음
- 양도로 생성된 새 device 행도 최초 출고와 동일하게 credential 재프로비저닝 필요

현재 claim API는 이미 DB에 등록된 미소유(UNCLAIMED) 기기와 그 기기의 credential이 존재한다는 전제로 동작한다.

#### 4.2 외부 기기 통신 보안

- 현재 Mosquitto 1883은 loopback 전용이므로 실제 기기가 접속할 수 없음
- MQTTS 8883과 TLS 인증서 구성 필요
- 공유 MQTT 계정이 아닌 기기별 인증과 topic ACL 필요
- MediaMTX RTSP 8554도 loopback 전용이므로 실제 기기 publish 불가
- RTSPS/SRT 등 실제 publish 방식과 기기별 인증 결정 필요
- 필요한 포트를 결정한 뒤 UFW를 최소 범위로 추가

보안 구성이 끝나기 전에 1883이나 8554를 인터넷에 그대로 공개하면 안 된다.

#### 4.3 Jetson/Raspberry Pi 프로그램

- 카메라·마이크 H.264/AAC 인코딩
- 순환 버퍼 유지
- 웃음·호출·터치 이벤트 처리
- 로컬 MP4 생성과 재시도 큐
- HTTPS 업로드 URL 요청과 MinIO PUT
- MQTT heartbeat/status/registration 발행
- START·EXTEND·STOP 명령과 ACK 처리
- MediaMTX로 live stream publish

백엔드는 메시지와 API 계약을 구현했지만 실제 하드웨어 프로그램은 별도 구현 대상이다.

#### 4.4 프론트엔드 연동

- 회원가입·로그인·refresh rotation
- 기기 claim과 멤버 관리
- 영상 목록·상세·편집·삭제
- live session 생성 후 `PENDING` polling
- 15초 heartbeat
- 30초 단기 live token 갱신
- HLS playlist·segment 요청의 token/cookie 동작 검증
- 앱 종료·화면 이탈 시 stream session DELETE

특히 HLS 인증은 실제 브라우저와 HLS.js 환경에서 cross-origin/cookie 동작을 추가 검증해야 한다.

### P1: 운영 전에 필요

#### 4.5 자동 보존 정책

2026-07-20 구현 완료: 만료 스케줄러(60초 주기), 업로드·편집 시 `retention_until` 기록, 구독 연동 재계산.
남은 결정: 사용자 즐겨찾기·법적 보존 예외 정책(MVP는 예외 없이 일괄 적용).

#### 4.6 초대 전달 방식

2026-07-20 초대 링크+OWNER 승인 방식으로 구현 완료. 남은 작업: 초대 링크의 frontend 딥링크 route 구현.

#### 4.7 백업과 복구

- PostgreSQL 정기 dump와 복구 훈련
- MinIO 객체 백업 또는 외부 S3 전환
- Docker volume 장애 복구 절차
- 서버 초기화에 대비한 off-instance 백업

#### 4.8 배포 자동화

- GitLab CI에서 test와 bootJar 실행
- 실패 시 배포 차단
- JAR 또는 Docker image 버전 관리
- 무중단 또는 최소 중단 배포
- rollback 절차
- `latest` image 대신 검증된 image version 고정

#### 4.9 모니터링

- Spring Actuator metrics 수집
- CPU·메모리·디스크·DB·MinIO·MQTT 상태 알림
- 업로드 실패율과 처리 지연 추적
- FFmpeg 실패와 orphan object 알림
- 인증 실패·claim 제한·MQTT schema 오류 보안 모니터링
- 로그 보존과 rotation

#### 4.10 운영 보안 보완

- Nginx의 `X-Forwarded-For`를 Spring에서 신뢰하도록 설정해 실제 사용자 IP 기록
- secret 정기 rotation
- 기기 credential rotation
- 관리자용 MinIO console 접근 방법을 SSH tunnel 등으로 제한
- 의존성·Docker image 취약점 검사

### P2: 품질 개선

- Testcontainers 기반 PostgreSQL·MinIO·Mosquitto 자동 통합 테스트
- 실제 FFmpeg 파일을 사용하는 편집 통합 테스트
- MediaMTX까지 포함한 live end-to-end 테스트
- OpenAPI와 실제 응답 schema 자동 비교
- 내부 `/api/live/introspect` 계약 문서화
- 부하 테스트와 동시 시청자 수 측정
- 코드 패키지별 README와 학습 문서 보강

## 5. 다음 작업 권장 순서

```text
1. 기기 provisioning 방식 확정·구현
2. MQTTS 기기별 인증/ACL 구성
3. MediaMTX 외부 publish 방식과 인증 구성
4. Jetson/Raspberry Pi heartbeat·명령 처리 연결
5. 실제 카메라 live end-to-end 검증
6. 영상 업로드 end-to-end 검증
7. 프론트엔드 API·HLS 연동
8. 자동 보존 scheduler
9. 백업·모니터링·GitLab CI/CD
```

지금 당장 백엔드에서 이어서 구현할 첫 작업은 **기기 provisioning 도구와 운영 등록 절차**다. 이 작업이 완료되어야 실제 기기가 claim, REST 인증, MQTT, live publish 흐름에 진입할 수 있다.

## 6. 자주 사용하는 확인 명령

### 로컬

```powershell
cd C:\higher\S15P11E201\backend
docker compose up -d

cd server
.\gradlew.bat test
.\gradlew.bat bootRun
```

### EC2

```bash
sudo systemctl status william-james
sudo journalctl -u william-james -f

cd /home/ubuntu/william-james/infra
docker compose ps
docker compose logs -f

curl https://i15e201.p.ssafy.io/health
sudo ufw status numbered
```

## 7. 절대 저장소에 올리면 안 되는 파일

- `*.pem`
- `.env`
- `/home/ubuntu/william-james/secrets/app.env` 내용
- DB 비밀번호
- MinIO access/secret key
- JWT signing key
- MQTT 비밀번호
- 등록 코드 원문 (로그·문서 기록 금지, 화면 표시와 발급 응답에만 존재)
- 사용자 access/refresh token

저장소의 `.gitignore`에 해당 기본 패턴을 추가해 두었다.
