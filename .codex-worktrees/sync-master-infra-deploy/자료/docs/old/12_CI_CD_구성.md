# CI/CD 구성 문서

## 1. 범위

| 단계 | 구성 | 파일 |
| --- | --- | --- |
| `[기본]` | PR·브랜치 테스트 | `.github/workflows/ci.yml` |
| `[기본]` | 수동 승인형 비민감 데모 인프라 배포 골격 | `.github/workflows/deploy.yml` |
| `[기본]` | PostgreSQL·MinIO·Mosquitto·Swagger UI | `infra/docker-compose.yml` |
| `[심화]` | 백엔드·스트리밍 서버 무중단 배포 | 애플리케이션 Dockerfile 생성 후 추가 |
| `[심화]` | 모바일 스토어 배포 | Android 서명키와 Play Console 준비 후 추가 |

## 2. 브랜치 전략

```text
main       배포 가능한 기준 브랜치
develop    기능 통합 브랜치
feature/*  기능 개발
fix/*      오류 수정
docs/*     문서 변경
```

- `feature/* → develop`: CI 통과와 리뷰 1명 이상을 권장한다.
- `develop → main`: 통합 테스트·시연 리허설 완료 후 병합한다.
- 현재 workflow는 비민감 데모 환경만 수동 배포한다. 실제 운영 배포는 범위 밖이며 TLS·기기별 MQTT ACL·저장 암호화·애플리케이션 이미지·롤백이 준비되기 전에는 활성화하지 않는다.

## 3. CI 동작

| 작업 | 현재 동작 |
| --- | --- |
| 산출물 검사 | 요구사항·ERD·테스트·OpenAPI·SQL·Compose 파일 존재 여부 확인 |
| OpenAPI | Redocly CLI로 문법·계약 검사 |
| 인프라 | 예시 환경 변수를 이용해 Docker Compose 구성 검사 |
| Markdown | 코드 블록 닫힘 여부 검사 |
| 백엔드 | `backend/`에 Gradle 또는 Maven 프로젝트가 생기면 Java 21 테스트 실행 |
| Flutter | `mobile/pubspec.yaml`이 생기면 분석과 테스트 실행 |
| IoT·AI | `iot/tests`, `ai/tests`가 생기면 pytest 실행 |

## 4. 로컬 인프라 실행

```powershell
Copy-Item infra/.env.example infra/.env
# infra/.env의 CHANGE_ME 값을 모두 교체
docker compose --env-file infra/.env -f infra/docker-compose.yml config
docker compose --env-file infra/.env -f infra/docker-compose.yml up -d
docker compose --env-file infra/.env -f infra/docker-compose.yml ps
```

기본 바인딩 주소는 `127.0.0.1`이다. Jetson·Raspberry Pi에서 접근해야 할 때만 `BIND_ADDRESS`를 서버의 사설 LAN 주소로 변경하고, 시연망 밖으로 포트를 공개하지 않는다.

## 5. GitHub 배포 설정

### Repository Variable

| 이름 | 예시 | 설명 |
| --- | --- | --- |
| `DEMO_DEPLOY_ENABLED` | `true` | 비민감 데모 배포 작업만 활성화. 준비 전에는 생성하지 않거나 `false` 유지 |
| `DEPLOY_PATH` | `/opt/william-james` | 서버 배포 경로 |

### Demo Environment Secret

| 이름 | 설명 |
| --- | --- |
| `DEPLOY_HOST` | 배포 서버 호스트명 또는 IP |
| `DEPLOY_USER` | 최소 권한 배포 사용자 |
| `DEPLOY_SSH_KEY` | 배포 전용 개인키 |
| `DEPLOY_HOST_KEY` | 사전에 검증한 SSH known_hosts 한 줄 |

서버의 `infra/.env`는 CI가 업로드하지 않는다. 운영 비밀값은 서버에서 별도로 생성·보관한다.
현재 데모 workflow는 `BIND_ADDRESS=127.0.0.1`을 강제한다. 포함된 Mosquitto 설정은 평문 1883·공유 개발 계정이며 기기별 ACL이 없고, MinIO Compose도 운영 KMS/SSE를 구성하지 않으므로 실제 사용자·기기·영상에는 사용할 수 없다.

### 운영 배포 전 필수 게이트

1. MQTTS 또는 검증된 TLS 종료 계층과 기기별 자격 증명·topic ACL을 구성한다.
2. MinIO KMS/SSE 또는 AWS S3 기본 암호화와 키 회전 정책을 구성한다.
3. Nginx/API/미디어 계층의 TLS·인증·비공개 관리 포트를 검증한다.
4. 별도 `production` 환경 보호 규칙, 승인자, 스모크 테스트와 롤백을 만든다.

## 6. 애플리케이션 코드 추가 후 보완

1. `backend/Dockerfile`, `iot/Dockerfile` 등 실제 실행 이미지를 작성한다.
2. 컨테이너 이미지를 GitHub Container Registry에 푸시한다.
3. `docker-compose.yml`에 백엔드와 미디어 처리 서비스를 추가한다.
4. Spring Actuator 기반 readiness·liveness 상태 검사를 추가한다.
5. DB 마이그레이션 도구(Flyway)를 도입하고 `schema.sql`은 설계 기준 문서로 전환한다.
6. 배포 성공 후 로그인·영상 목록·서명 URL 발급에 대한 스모크 테스트를 실행한다.
7. 실패 시 이전 이미지 태그로 되돌리는 롤백 절차를 자동화한다.

## 7. 데모 배포 완료 기준

- CI의 모든 적용 대상 작업이 통과한다.
- 운영 서버의 비밀값이 Git·로그·아티팩트에 노출되지 않는다.
- PostgreSQL·MinIO·Mosquitto가 내부망 또는 허용된 주소에서만 접근된다.
- Swagger UI는 시연 환경에서만 공개하거나 인증 뒤에 둔다.
- 배포 후 핵심 스모크 테스트와 권한 격리 테스트가 통과한다.
- 테스트 결과서에 실행 일시, 커밋, 담당자와 증적을 기록한다.
