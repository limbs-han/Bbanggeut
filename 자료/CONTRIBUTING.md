# 협업 규칙

## 작업 시작

1. 요구사항 ID와 담당자를 확인한다.
2. `develop` 최신 상태에서 작업 브랜치를 만든다.
3. API·MQTT·DB 계약 변경은 구현 전에 관련 직무와 합의한다.

```bash
git fetch origin --prune && git switch develop && git pull --ff-only origin develop
```

브랜치 이름은 `<종류>/<파트>/<요구사항ID-설명>` 형태로 쓴다.
파트 접두사는 Jenkins가 실행할 CI 단계를 고르는 데 쓰이므로 생략하지 않는다.

```text
feat/device/FR-DEVICE-001-claim-device
feat/frontend/FR-VIDEO-004-trim-video
fix/backend/TC-SEC-003-device-membership-access
docs/openapi-video-edit
```

전체 브랜치 규칙은 저장소 루트의 `AGENTS.md`와
`ai/GIT_BRANCH_RULES.txt`에 있다. 요약하면 다음과 같다.

- 모든 작업 브랜치는 `develop`에서 만들고 `develop`으로 Merge Request를 만든다.
- `master`는 `develop`에서만 병합받는다. `master`로 직접 MR을 만들지 않는다.
- 병합 후 작업 브랜치는 삭제한다. `develop`과 `master`는 삭제하지 않는다.

## 커밋

```text
feat: 기기 최초 등록 API 추가
fix: 권한 회수 후 재생 URL 발급 차단
test: 반복 웃음 병합 테스트 추가
docs: 영상 편집 API 예시 보완
chore: CI 캐시 설정 변경
```

한 커밋에는 하나의 논리적 변경만 포함하고, 영상·모델·비밀키·실제 사용자 데이터는 커밋하지 않는다.

## Merge Request 체크리스트

- [ ] 연결된 요구사항·이슈 ID를 적었다.
- [ ] 기본·심화 범위를 벗어나지 않는다.
- [ ] 신규 또는 변경된 로직에 테스트가 있다.
- [ ] `DeviceMembership`이 없는 다른 기기의 리소스에 접근할 수 없는지 확인했다.
- [ ] API·DB·MQTT 계약 변경을 문서에 반영했다.
- [ ] 로그에 토큰, 등록 코드, 영상 URL, 개인정보를 남기지 않는다.
- [ ] 네트워크 실패·재시도·중복 요청을 고려했다.
- [ ] CI가 통과한다.

## 완료 정의

기능은 코드 작성만으로 완료되지 않는다. 다음 조건을 모두 만족해야 한다.

1. 요구사항의 인수 조건을 충족한다.
2. 정상·오류·권한 테스트가 존재하고 실행 결과가 기록된다.
3. API·화면·DB·MQTT 문서가 현재 구현과 일치한다.
4. 다른 직무가 통합할 수 있는 사용 예시 또는 테스트 데이터가 있다.
5. PM이 통합 시나리오에서 확인할 수 있다.
