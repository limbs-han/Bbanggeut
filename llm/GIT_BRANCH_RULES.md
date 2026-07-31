# S15P11E201 Git 브랜치 규칙

저장소의 기본 브랜치는 master다.
main이라는 브랜치는 사용하지 않는다.

## 장기 브랜치

- develop: 전 파트(Backend, Frontend, Device/AI) 공통 통합 브랜치
- master: 배포 기준 브랜치

파트별 develop 브랜치는 없다.
Backend, Frontend, Device 모두 같은 develop 하나를 쓴다.

master와 develop에는 직접 push하지 않는다. 항상 Merge Request를 쓴다.
master와 develop은 삭제하지 않는다.

### 핵심 규칙: master는 develop에서만 병합받는다

master로 들어오는 병합은 develop → master 하나뿐이다.
기능, 수정, 문서, 설정 무엇이든 master로 직접 MR을 만들지 않는다.

이 규칙 때문에 master는 항상 develop의 부분집합이 된다.
master에만 있고 develop에 없는 커밋이 생기지 않으므로
master를 develop으로 되돌려 받는 역머지가 필요 없다.

이전 규칙에 있던 역머지, chore/sync-*, chore/integrate-* 절차는
모두 폐지한다. develop이 3개라서 필요했던 작업이다.

## 기능 브랜치

파트를 알아보기 위해 접두사를 붙이되, 만드는 곳과 돌아가는 곳은
모두 develop으로 같다.

    feat/backend/<기능명>      새 기능
    feat/frontend/<기능명>
    feat/device/<기능명>       IoT, Raspberry Pi, Jetson, AI
    feat/jenkins-<작업명>      Jenkins와 CI/CD

    fix/backend/<버그명>       버그 수정
    fix/frontend/<버그명>
    fix/device/<버그명>

    docs/<주제>                문서만 바꾸는 경우
    chore/<작업명>             빌드, 설정, 파일 정리

브랜치 이름에 codex, 사용자 이름, 의미 없는 숫자를 쓰지 않는다.

기능 브랜치는 짧게 유지한다. 하루에서 사흘 안에 병합하고 삭제한다.
오래 살아 있는 기능 브랜치는 develop과 벌어져서 충돌을 만든다.

## 작업 시작

파트와 관계없이 명령이 같다.

    git fetch origin --prune
    git switch develop
    git pull --ff-only origin develop
    git switch -c feat/backend/<기능명>

develop이 최신인지만 확인하면 된다.
어느 develop이 뒤처졌는지 확인하는 절차는 더 이상 없다.

## Merge Request 대상

모든 기능 브랜치의 MR 대상은 develop이다.

    feat/*   -> develop
    fix/*    -> develop
    docs/*   -> develop
    chore/*  -> develop

master를 대상으로 하는 MR은 develop -> master 하나뿐이다.

## CI 확인

Frontend CI:

- flutter pub get
- flutter analyze
- flutter test
- APK와 AAB를 빌드하지 않는다.
- Frontend CD는 존재하지 않는다.

Backend CI:

- Backend 빌드
- 단위 테스트
- PostgreSQL 통합 테스트

Device CI:

- Device Agent 테스트
- AI Python 테스트
- Python 및 Shell 문법 검사

API Contract CI:

- 자료/api/openapi.yaml 계약 검사

CI가 실패하면 병합하지 않는다.
문제를 고쳐 같은 기능 브랜치에 다시 push한다.

Jenkinsfile은 브랜치 이름으로 실행할 단계를 고른다.

- master와 develop: 네 단계를 모두 실행한다.
- feat/backend/**, fix/backend/**: Backend와 API Contract
- feat/frontend/**, fix/frontend/**: Frontend와 API Contract
- feat/device/**, fix/device/**: Device와 API Contract
- docs/**, chore/**: API Contract

파트 접두사를 빠뜨리거나 틀리게 쓰면 해당 파트 CI가 실행되지 않는다.
이때 MR은 실패가 아니라 초록색으로 보이므로 알아채기 어렵다.
브랜치 이름을 규칙대로 쓰는 이유가 이것이다.

## 병합과 브랜치 삭제

CI가 통과하면 기능 브랜치를 develop에 병합한다.

Merge Request 옵션:

- Squash commits: 기본은 꺼져 있다.
  브랜치가 시행착오 커밋 뭉치(wip, 테스트 수정, 오타 등)면 켜서
  develop에 커밋 하나로 남긴다.
  각 커밋이 독립된 논리 변경이면 끈 채로 병합한다.
- Delete source branch when merge request is accepted를 켠다.

삭제하면 안 되는 브랜치:

- master
- develop

기능 브랜치는 병합 후 남겨 두지 않는다.

## master 반영

배포가 필요할 때 develop에서 master로 Merge Request를 만든다.

    develop -> master

이때 Squash를 켜지 않는다. 기본값이 꺼져 있으므로 그대로 두면 된다.
커밋 이력을 눌러 붙이면 master와 develop의 이력이 갈라져
다음 번 develop -> master 병합부터 충돌이 생긴다.

source branch 삭제 옵션도 끈다. develop은 보호 브랜치라 실제로
삭제되지는 않지만, 옵션을 꺼 두는 쪽이 의도가 분명하다.

병합 후에 할 일은 없다. 역머지하지 않는다.

## 급한 수정

운영에 급한 문제가 생겨도 master로 직접 MR을 만들지 않는다.

develop에서 fix/<파트>/<버그명> 브랜치를 만들고,
develop에 병합한 뒤, 바로 develop -> master MR을 만든다.

develop은 CI를 통과한 상태로만 유지되므로 이 경로가 느리지 않다.
master로 직행하는 예외를 한 번 허용하면 master가 develop보다
앞서게 되고, 폐지한 역머지 절차가 다시 필요해진다.

## 문서 동기화

코드를 바꾸면 그 기능과 관련된 문서를 같이 고친다.

문서 경로:

    자료/docs

문서에 실제 변경 사항을 반영한다.

- 추가하거나 바꾼 기능
- API, 설정값, 실행 방법의 변경
- 구조 또는 동작 방식의 변경
- 사용자가 알아야 할 주의 사항

관련 문서가 있으면 그 문서를 고치고, 없으면 새로 쓴다.
변경과 관계없는 문서는 건드리지 않는다.
다른 파트가 쓴 서술을 지우지 않는다.

문서 변경은 코드 변경과 같은 기능 브랜치, 같은 MR에 넣는다.
문서가 필요한 변경인데 문서를 갱신하지 않았으면
push하거나 MR을 만들지 않는다.

## 공유 파일

다음 파일은 세 파트가 모두 고친다.

- 자료/docs/**
- 자료/api/openapi.yaml

문서 한 줄에 사실 하나만 쓴다.
표 한 행이나 불릿 하나에 여러 사실을 몰아 쓰면,
서로 다른 파트가 서로 다른 사실을 고쳐도 같은 줄이 되어
충돌이 발생한다.

충돌이 나면 한쪽을 통째로 고르지 않는다.
양쪽에 서로 다른 사실이 들어 있어 한쪽을 버리면 내용이 사라진다.

1. 충돌 구간의 양쪽을 모두 읽는다.
2. 각 항목이 어느 파트의 실제 코드 변경을 설명하는지 확인한다.
3. 코드와 맞는 쪽을 항목 단위로 고른다.
4. 양쪽 다 유효하면 두 줄을 모두 남긴다.
5. 해결한 뒤 서술이 실제 코드와 맞는지 다시 확인한다.

develop이 하나이므로 이 충돌은 기능 브랜치를 develop에 병합할 때만
발생한다. develop을 자주 pull하면 충돌 범위가 작아진다.

## 배포

Frontend:

- CI까지만 수행한다.
- 실제 기기 실행은 개발자 PC에서 flutter run으로 확인한다.
- APK, AAB, 앱 스토어 자동 배포를 하지 않는다.

Device와 AI:

- CI까지만 수행한다.
- 장치나 EC2에 자동 배포하지 않는다.

Backend:

- master CI가 성공하면 운영 배포 승인 작업이 생성된다.
- 사용자 요청 없이 운영 배포를 승인하지 않는다.
- 필요 없는 배포 작업은 Abort한다.

## LLM 작업 절차

1. 저장소 루트의 AGENTS.md를 읽는다.
2. git status와 현재 브랜치를 확인한다.
3. git fetch origin --prune을 실행한다.
4. develop에서 규칙에 맞는 이름의 기능 브랜치를 만든다.
5. 코드와 테스트를 작성한다.
6. 바꾼 내용과 관련된 자료/docs 문서를 고치거나 새로 쓴다.
7. 로컬 검증을 수행한다.
8. 코드와 문서의 내용이 서로 맞는지 확인한다.
9. 변경 파일과 diff를 확인한다.
10. 기능 브랜치에만 commit과 push를 한다.
11. develop을 대상으로 Merge Request를 만든다.
12. CI 결과를 확인하고, 성공한 뒤에만 병합한다.
13. 병합 후 기능 브랜치를 삭제한다.
14. 각 단계의 결과를 한국어로 쉽게 보고한다.

사용자가 master로 바로 병합해 달라고 요청하더라도,
develop을 거치는 절차를 먼저 안내한다.
master에 직접 커밋하거나 push하지 않는다.
