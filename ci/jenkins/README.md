# Jenkins CI 구성

Jenkins Controller는 작업을 관리하기만 하고 소스 코드를 직접 빌드하지
않습니다. 실제 테스트와 빌드는 영역별로 분리된 Jenkins Agent가 수행합니다.

| Agent 라벨 | 필요한 도구 | 담당 경로 |
|---|---|---|
| `backend` | JDK 17, Bash, PostgreSQL Client | `backend/` |
| `frontend` | Flutter 3.44.7 이상, Dart 3.12 이상, Bash | `frontend/` |
| `iot` | Python 3, venv, Bash | `ai/device_agent/` |
| `ai` | Python 3, Bash | `ai/yolo/`의 하드웨어 독립 코드 |

Agent는 작업을 시작할 때 GitLab 코드를 임시 작업 폴더에 내려받습니다.
작업이 끝나면 작업 폴더를 삭제하므로 Agent의 파일은 배포본이나 백업으로
사용하지 않습니다.

## 브랜치별 실행 범위

Jenkins는 Multibranch Pipeline으로 구성하며 저장소 루트의 `Jenkinsfile`을
사용합니다.

| 브랜치 | 실행하는 CI |
|---|---|
| `master` | Backend, Frontend, IoT, AI 전체 |
| `develop` | Backend, Frontend, IoT, AI 전체 |
| `develop/backend`, `feat/backend/**` | Backend |
| `develop/frontend`, `feat/frontend/**` | Frontend |
| `develop/iot`, `feat/iot/**` | IoT |
| `develop/ai`, `feat/ai/**` | AI |

초기 구축용 `feat/jenkins-pipeline` 브랜치에서는 Agent와 Pipeline을 한 번에
검증하기 위해 모든 영역을 실행합니다.

`Jenkinsfile`은 브랜치를 생성하지 않습니다. `develop`과 영역별 브랜치를
만들고 보호하는 작업은 별도의 GitLab 관리 단계에서 수행합니다.

## PostgreSQL 통합 테스트

현재 `FlywayMigrationIntegrationTest`에는 다음 설정이 있습니다.

```java
@Testcontainers(disabledWithoutDocker = true)
```

이 설정 때문에 Docker를 사용할 수 없는 환경에서는 테스트가 실패하지 않고
자동으로 제외됩니다. Jenkins Controller와 안전한 Backend Agent에는 운영
Docker를 제어하는 `/var/run/docker.sock`을 연결하지 않으므로, 현재 상태로는
이 테스트가 Jenkins에서 실행되지 않습니다.

운영 PostgreSQL을 테스트에 사용하면 안 됩니다. 후속 Agent 구성 단계에서
다음과 같이 Jenkins 전용 PostgreSQL을 별도로 연결합니다.

```text
william-james-jenkins-agents 네트워크
├─ backend-agent
└─ postgres-ci
```

`postgres-ci`의 원칙은 다음과 같습니다.

- 운영 Compose 및 운영 PostgreSQL과 완전히 분리
- 호스트 포트를 외부에 공개하지 않음
- 테스트 전용 계정과 비밀번호 사용
- 메모리 기반 임시 저장소 사용
- 빌드마다 고유한 데이터베이스 생성
- 테스트가 끝나면 데이터베이스 삭제

Backend Agent는 다음 환경변수로 테스트 DB에 연결합니다.

```text
TEST_POSTGRES_HOST=postgres-ci
TEST_POSTGRES_PORT=5432
TEST_POSTGRES_ADMIN_DATABASE=postgres
TEST_POSTGRES_ADMIN_USER=jenkins
TEST_POSTGRES_ADMIN_PASSWORD=<Jenkins 전용 비밀값>
```

테스트 코드에는 외부 테스트 DB가 제공되면 이를 사용하는 통합 테스트를
추가합니다. 개발자 PC에서 Docker를 사용할 때는 기존 Testcontainers 테스트도
계속 사용할 수 있게 유지합니다.

PostgreSQL CI 환경의 완료 조건은 다음과 같습니다.

1. 운영 PostgreSQL에 접속하지 않는다.
2. Flyway 마이그레이션 전체가 빈 PostgreSQL 16 DB에 적용된다.
3. 목표 스키마 버전 `15`를 확인한다.
4. 필수 테이블 생성을 확인한다.
5. 테스트 결과가 Jenkins JUnit 보고서에 실행됨으로 표시된다.
6. 테스트 종료 후 임시 DB가 삭제된다.

이 작업은 Jenkins Agent 구성 및 CI 실행 검증 단계에 포함합니다.

## AI 테스트 범위

일반 AI Agent에서는 다음 항목을 검사합니다.

- 이벤트 결합 로직 테스트
- 영상 업로드 메타데이터 테스트
- Python 문법 검사
- 셸 스크립트 문법 검사

YOLO 자동 구도 테스트는 Jetson 전용 Torch, OpenCV, Ultralytics 환경을
요구합니다. CPU 호환 CI 이미지를 고정하기 전까지는 Jetson 하드웨어 검증
단계로 분리합니다.
