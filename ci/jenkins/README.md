# Jenkins CI 구성

Jenkins Controller는 작업을 관리하기만 하며 프로젝트 코드를 직접 빌드하지 않습니다.
실제 빌드와 테스트는 영역별 Jenkins Agent가 수행합니다.

## 현재 적용된 구성

| 서비스 | 실행 도구 | 담당 경로 |
|---|---|---|
| `backend-agent` | Jenkins 연결용 JDK 21, Gradle용 JDK 17, Python, PostgreSQL Client | `backend/` |
| `frontend-agent` | JDK 21, Flutter 3.44.7, Dart 3.12.2 | `frontend/` |
| `device-agent` | JDK 21, Python 3, venv, Bash | `ai/device_agent/`와 `ai/yolo/` |
| `postgres-ci` | PostgreSQL 16 | Backend 통합 테스트 전용 |

서버 구성 파일은 `ci/jenkins/server/`에 있습니다.

- `compose.yml`: Controller, 네 Agent, `postgres-ci`, 전용 네트워크 정의
- `Dockerfile.controller`: Jenkins Controller와 플러그인
- `Dockerfile.agent`: Backend·IoT·AI 공통 Agent
- `Dockerfile.frontend-agent`: Flutter Agent
- `init.groovy.d/20-domain-agents.groovy`: 영역별 Agent 노드 생성
- `init.groovy.d/30-gitlab-multibranch.groovy`: GitLab Credentials와 Multibranch 작업 생성
- `init.groovy.d/35-gitlab-status.groovy`: Jenkins CI/CD 결과를 GitLab 커밋 상태로 전송
- `init.groovy.d/40-git-notify-security.groovy`: Push 알림을 Polling 전용으로 제한

## 보안 및 격리

- Controller와 Agent에는 `/var/run/docker.sock`을 연결하지 않습니다.
- Agent와 `postgres-ci`는 `william-james-jenkins-agents` 네트워크만 사용합니다.
- 운영 서비스가 사용하는 `william-james_default` 네트워크에는 들어가지 않습니다.
- `postgres-ci`의 5432 포트는 호스트에 공개하지 않습니다.
- `postgres-ci` 데이터 디렉터리는 메모리 기반 `tmpfs`입니다.
- GitLab 저장소는 만료일이 있는 `read_repository` 전용 Deploy Token으로 읽습니다.
- Deploy Token은 Jenkins Credentials에 저장하고 작업에는 Credential ID만 기록합니다.
- GitLab 상태 기록은 프로젝트 전용 `api` 토큰을 별도 사용하며
  `/home/ubuntu/jenkins-agent-secrets/gitlab-api-token`에만 저장합니다.

Jenkins Controller가 Java 21로 실행되므로 Agent 연결 프로그램도 Java 21을 사용합니다.
Backend Gradle 설정은 Java 17 toolchain을 요구하므로 공통 Agent에는 Java 17을 별도 경로로
함께 설치했습니다.

## GitLab 연결과 Webhook

Jenkins에는 `S15P11E201` Multibranch Pipeline이 구성돼 있습니다. GitLab Push 이벤트가 발생하면
다음 순서로 동작합니다.

```text
GitLab Push
  -> Jenkins notifyCommit
  -> S15P11E201 브랜치 재확인
  -> 변경된 브랜치에 Jenkinsfile이 있으면 CI 실행
```

`notifyCommit`은 `disabled-for-polling` 모드입니다. 토큰 없는 요청으로 저장소 재확인만 가능하며,
SHA를 지정해 특정 빌드를 직접 실행하는 요청은 HTTP 401로 차단됩니다.

추가 안전장치로 5분 주기의 Multibranch 재확인도 설정돼 있습니다. Webhook이 일시적으로 실패해도
다음 주기에서 새 브랜치를 발견할 수 있습니다.

## 브랜치별 실행 범위

| 브랜치 | 실행되는 CI |
|---|---|
| `master` | Backend, Frontend, IoT, AI 전체 |
| `develop/backend`, `feat/backend/**` | Backend |
| `develop/frontend`, `feat/frontend/**` | Frontend |
| `develop/device`, `feat/device/**` | IoT와 AI |

Jenkins 자체 구성을 바꾸는 검증 브랜치에서는 Backend, Frontend, Device 전체 CI를 실행하도록
해당 브랜치 이름을 `Jenkinsfile`에 명시합니다.

현재 GitLab의 `master`나 `develop/*` 브랜치는 자동으로 생성하거나 변경하지 않습니다.
브랜치 정책 적용은 별도의 GitLab 관리 단계에서 진행합니다.

## PostgreSQL 통합 테스트

현재 `FlywayMigrationIntegrationTest`는 외부 테스트 DB 환경변수가 있으면 해당 DB를 사용하고,
환경변수가 없으면 Testcontainers를 사용합니다.

개발자 PC에서 Docker를 사용할 수 있으면 임시 PostgreSQL 컨테이너를 만듭니다.
Jenkins Agent에는 운영 Docker를 제어할 수 있는 Docker 소켓이 없으므로 Jenkins 전용
`postgres-ci`를 사용합니다.

4단계에서는 운영 환경과 분리된 `postgres-ci`를 구성하고 Backend Agent에서
`postgres-ci:5432` 연결이 가능한 것까지 확인했습니다.

테스트는 다음 방식으로 실행됩니다.

```text
로컬 개발 환경
  -> Docker 사용 가능
  -> 기존 Testcontainers 테스트 실행

Jenkins Backend Agent
  -> Docker 소켓 없음
  -> postgres-ci에 빌드별 임시 데이터베이스 생성
  -> Flyway 통합 테스트 실행
  -> 테스트가 끝나면 임시 데이터베이스 삭제
```

빌드별 DB 이름은 Jenkins 작업 이름의 해시와 빌드 번호로 만들기 때문에 다른 브랜치의 빌드와
충돌하지 않습니다. 성공·실패와 관계없이 실행 스크립트의 종료 처리에서 DB를 삭제합니다.

PostgreSQL CI 완료 조건은 다음과 같습니다.

1. 운영 PostgreSQL에 접속하지 않습니다.
2. 깨끗한 PostgreSQL 16 DB에 Flyway 마이그레이션 전체를 적용합니다.
3. 목표 스키마 버전 `16`을 확인합니다.
4. 필수 테이블 생성을 확인합니다.
5. Jenkins JUnit 보고서에서 테스트가 `SKIPPED`가 아니라 실행된 것으로 표시됩니다.
6. 테스트 종료 후 빌드 전용 임시 DB가 삭제됩니다.

## Frontend CI

Frontend CI는 의존성 설치, 정적 분석, 자동 테스트까지만 수행합니다.

```text
flutter analyze
  -> flutter test
```

휴대폰에서의 실제 실행은 개발자 PC에 기기를 연결한 뒤 `flutter run`으로 확인합니다.
Jenkins 서버에는 물리 Android 기기가 연결되어 있지 않으므로 `flutter run`을 수행하지 않습니다.
Frontend CD 작업은 구성하지 않습니다. Jenkins Frontend Agent에도 Android SDK, Build Tools,
NDK를 설치하지 않으며 APK·AAB 생성, 기기 설치, 앱 스토어 업로드를 수행하지 않습니다.

## Backend 운영 배포

운영 배포는 `Production/S15P11E201-backend-deploy`라는 저장소 외부의 신뢰된 Jenkins 작업이
담당합니다. 일반 브랜치의 Jenkinsfile에서는 운영 SSH 자격증명에 접근할 수 없습니다.

```text
S15P11E201/master CI 성공
  -> Production 작업 자동 생성
  -> 사람의 배포 승인 대기
  -> master 빌드의 JAR artifact만 복사
  -> 전용 jenkins-deploy 계정으로 EC2에 업로드
  -> 현재 JAR 백업
  -> Spring Boot systemd 서비스만 재시작
  -> health 성공 시 완료
  -> health 실패 시 이전 JAR로 복구
```

운영 PostgreSQL·MinIO·Mosquitto·MediaMTX Compose는 Backend JAR 배포 과정에서 재시작하지
않습니다. Frontend, IoT, AI는 CI까지만 수행하며 자동 CD 대상이 아닙니다.

운영 EC2에는 실행용 JRE만 설치합니다. 배포 스크립트는 JDK의 `jar` 명령에 의존하지 않고
`unzip`으로 압축 손상과 `META-INF/MANIFEST.MF`, `BOOT-INF/classes/`, `BOOT-INF/lib/`
구조를 확인합니다. Backend CI도 같은 검증기로 실제 빌드 결과물을 검사합니다.

## GitLab 상태 알림

Jenkins는 테스트와 배포 결과를 GitLab 커밋과 Merge Request 화면에 다음 이름으로 표시합니다.

| 상태 이름 | 의미 |
|---|---|
| `ci/backend` | Backend 빌드, 단위 테스트, PostgreSQL 통합 테스트 |
| `ci/frontend` | Flutter 의존성 설치, 분석, 자동 테스트 |
| `ci/device` | Device Agent와 AI 테스트 |
| `deploy/production` | Backend 운영 배포 승인 대기와 배포 결과 |

상태는 실행 중 `running`, 성공 시 `success`, 실패 시 `failed`, 취소나 승인 시간 초과 시
`canceled`가 됩니다. GitLab에는 Jenkins 빌드 상세 화면으로 이동하는 링크도 함께 표시됩니다.
Jenkins 공개 주소는 `http://i15e201.p.ssafy.io:8080/`로 설정되어 이 링크가 실제 Jenkins
빌드 화면을 가리킵니다.

## 현재 검증 결과

- 영역별 Agent가 각각 `backend`, `frontend`, `device` 라벨로 Jenkins에 연결됨
- Backend Agent에서 Java 21과 Gradle용 Java 17을 모두 실행함
- Backend Agent에서 `postgres-ci:5432` 연결 성공
- Controller와 네 Agent의 Docker 소켓 미연결 확인
- Agent와 테스트 DB가 운영 Docker 네트워크에 연결되지 않음
- GitLab Push Webhook 테스트 HTTP 200
- `feat/jenkins-pipeline`의 첫 전체 CI 성공

## AI 테스트 범위

일반 AI Agent에서는 다음 항목을 검사합니다.

- 이벤트 결합 로직 테스트
- 영상 업로드 메타데이터 테스트
- Python 문법 검사
- 셸 스크립트 문법 검사

YOLO 자동 구도 테스트는 Jetson 전용 Torch, OpenCV, Ultralytics 환경이 필요합니다.
CPU 호환 CI 이미지가 확정되기 전까지는 Jetson 하드웨어 검증 단계로 분리합니다.
