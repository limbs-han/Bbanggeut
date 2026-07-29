# Memory Vault와 기기 수명주기

## 1. 변경 목적

기존 구조는 계정 권한, 구독, 영상 보관과 물리 기기의 수명을
`device_id` 하나로 묶었다. 이 때문에 기기 연결 해제가 영상 삭제와
멤버십 폐기로 이어지고, 고장 교체·분실·중고 양도 후 과거 영상을
유지할 수 없었다.

변경 후 데이터 소유 단위는 `Memory Vault`다.

```text
User -> VaultMembership -> MemoryVault -> Video
                                  |
                                  +-> DeviceBinding -> Physical Device
```

물리 기기는 촬영 출처이며 교체 가능한 장치다. 영상, 구독, 보관 정책,
OWNER/MEMBER 관계는 금고에 귀속된다.

## 2. 테이블

### `memory_vaults`

- 영상과 구독의 소유·보안 경계
- `ACTIVE`, `CLOSING`, `CLOSED` 상태
- 기기가 한 대도 없어도 존재 가능

### `vault_memberships`

- 계정과 금고 사이의 OWNER/MEMBER 권한
- 활성 금고에는 정확히 한 명의 OWNER만 존재
- 기기 연결 해제 시 변경하지 않음
- MEMBER 회수 및 OWNER 이전은 금고 권한과 기존 호환 멤버십을 함께 변경

### `device_bindings`

- 물리 기기가 어느 금고에 연결되었는지 나타내는 기간 이력
- 물리 기기당 활성 Binding은 최대 한 건
- 재연결할 때 `generation`을 증가시켜 이전 연결과 구분
- 종료된 Binding은 재활성화·대상 변경이 불가능한 이력
- 종료 원인: `DISCONNECTED`, `REPLACED`, `SOLD`, `LOST`, `BROKEN`

### `videos.vault_id`

- 영상의 변경 불가능한 소유 금고
- `device_id`는 촬영 장치 출처로 유지
- `device_binding_id`는 촬영 당시 연결 이력

## 3. 주요 동작

### 최초 등록

`POST /api/devices/claim`에서 사용자는 다음 중 하나를 명시적으로
선택한다.

1. `vaultId`를 전달해 자신이 OWNER인 기존 금고에 연결
2. `vaultId`를 생략하고 `vaultName`을 전달해 새 금고 생성

활성 Binding의 금고는 중간에 바꿀 수 없다. 다른 금고를 선택하려면
현재 연결을 해제하고 기기를 다시 등록해야 한다.

### 기존 금고에 추가 또는 교체

`vaultId`를 전달한다. 요청 사용자가 해당 금고 OWNER일 때만 새 활성
Binding을 만들 수 있다. 하나의 금고에는 여러 물리 기기를 연결할 수
있다.

### 기기 연결 해제

`DELETE /api/devices/{deviceId}`는 다음 작업만 수행한다.

1. 활성 Binding을 `DISCONNECTED`로 종료한다.
2. 물리 기기를 `UNCLAIMED`로 되돌린다.
3. 기기 단위 호환 멤버십만 종료한다.
4. 라이브와 신규 업로드를 중단한다.

다음 데이터는 삭제하거나 폐기하지 않는다.

- Memory Vault
- VaultMembership
- 금고 단위 대기 초대
- 영상 및 오브젝트 스토리지 파일
- 금고 구독과 보관 정책

### 기기가 없는 금고

`GET /api/vaults`는 `devices: []`인 금고도 반환한다.
Flutter는 기기 등록 화면으로 강제 이동하지 않고 과거 영상을 조회한다.
라이브·신규 촬영만 사용할 수 없으며, 사용자는 같은 금고에 새 기기를
연결할 수 있다. OWNER는 기기 없이도 금고 구성원 초대·회수와 소유권
양도를 수행할 수 있다.

### 금고 구성원과 OWNER

- 구성원 조회·초대·회수는 `/api/vaults/{vaultId}/...` API를 사용한다.
- OWNER는 같은 금고의 활성 MEMBER 한 명에게 소유권을 양도할 수 있다.
- 양도는 금고에 연결된 모든 활성 기기의 호환 멤버십에도 동기화된다.
- OWNER는 스스로 탈퇴하거나 내보내질 수 없다. 먼저 소유권을 양도해야
  한다.
- 기기 연결 여부는 금고 구성원 관리 권한에 영향을 주지 않는다.

### 중고 양도

판매자의 Binding과 구매자의 Binding은 서로 다른 generation이다.
기존 영상의 `vault_id`는 판매자 금고에 고정되므로 구매자에게 이전되지
않는다. 물리 기기는 `UNCLAIMED` 상태에서 구매자의 금고에 새로 Binding
된다.

## 4. 접근 제어 불변식

1. 영상 조회·수정·삭제 권한은 `vault_memberships`로 판단한다.
2. 기기 한 대에는 활성 Binding이 최대 한 건이다.
3. 영상의 `vault_id`는 생성 후 변경하지 않는다.
4. 기기 연결 해제는 영상을 삭제하지 않는다.
5. 영상 삭제는 개별 삭제 요청 또는 보관 만료 작업만 수행한다.
6. 활성 금고 OWNER는 회원 탈퇴 전에 소유권을 이전해야 한다.
7. 구매자는 이전 Binding의 영상에 접근할 수 없다.
8. 활성 Binding의 `vault_id`는 수정할 수 없고, 종료된 Binding은
   어떠한 방식으로도 재활성화할 수 없다.
9. 금고 선택을 바꾸는 유일한 정상 흐름은 연결 해제 후 새 generation
   Binding을 만드는 재등록이다.

## 5. 호환성

기존 `device_memberships`와 기기 기준 API는 당분간 유지한다.
새 claim과 초대 수락 시 VaultMembership을 기준으로 호환 멤버십을
동기화한다. 신규 앱은 `/api/vaults`와 `vaultId` 영상 조회를 사용하며,
기기 라이브·상태 API는 활성 Binding이 있을 때만 사용한다.

## 6. 배포 주의 사항

- Flyway V29가 기존 claimed/revoked 기기와 영상을 금고로 백필한다.
- Flyway V30이 초대를 금고 기준으로 백필하고, 단일 OWNER 및 종료된
  Binding 불변식을 데이터베이스에서 강제한다.
- 활성 기기는 기존 OWNER/MEMBER를 그대로 이동한다.
- 이미 해제된 기기는 과거에 제거된 MEMBER를 복원하지 않고 기존
  `claimed_by` OWNER만 복원한다.
- 이미 오브젝트 스토리지에서 물리 삭제가 끝난 영상은 이 마이그레이션으로
  복구할 수 없다.
- Backend V29 배포 후 Vault API를 사용하는 Flutter를 배포한다.
