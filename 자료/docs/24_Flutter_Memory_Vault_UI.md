# Flutter Memory Vault 화면 전환

## 변경 목적

앱의 최상위 상태를 `selectedDevice`가 아닌 `selectedVault`로 변경한다.
기기 연결이 없어도 추억 금고와 과거 영상은 유지되며, 라이브와 신규
촬영만 사용할 수 없다.

## 초기 로딩

1. 로그인 후 `GET /api/vaults`를 호출한다.
2. 이전에 선택한 금고가 있으면 유지하고, 없으면 첫 금고를 선택한다.
3. 금고의 `devices`가 비어 있으면 `VaultArchiveScreen`을 연다.
4. 활성 기기가 있으면 기존 5탭 메인 화면을 연다.

금고가 하나도 없는 신규 계정만 전체 화면 기기 등록 흐름으로 이동한다.

## 기기 없는 금고 화면

- 금고 이름 표시
- `GET /api/videos?vaultId=...`로 과거 영상 조회
- “현재 연결된 기기가 없어요” 안내
- 새 기기 연결 버튼
- 새로고침 및 로그아웃

“연결된 기기가 없습니다. 추억 영상을 볼 수 없습니다.”라는 기존 동작은
사용하지 않는다.

## 기기 등록과 해제

- 기존 금고에서 등록하면 claim 요청에 `vaultId`를 포함한다.
- 최초 등록으로 금고가 없다면 `vaultId`를 생략하고 서버가 새 금고를 만든다.
- 기기 해제 성공 후 `GET /api/vaults`를 다시 호출한다.
- 해제된 기기는 선택 목록에서 사라지지만 `selectedVault`와 영상 목록은
  유지된다.

## 검증

Frontend CI 기준:

```text
flutter pub get
flutter analyze
flutter test
```

APK/AAB 빌드는 수행하지 않는다.
