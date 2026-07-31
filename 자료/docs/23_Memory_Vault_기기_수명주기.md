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
2. `vaultId`를 생략해 새 금고 생성(`vaultName`은 선택이며 기본 이름 제공)

활성 Binding의 금고는 중간에 바꿀 수 없다. 다른 금고를 선택하려면
현재 연결을 해제하고 기기를 다시 등록해야 한다.

따라서 연결이 해제된 기기를 등록한다고 해서 항상 새 금고가 자동으로
생기는 것은 아니다. 등록 요청에 `vaultId`가 있으면 기존 금고에,
없으면 새 금고에 연결된다. 새 금고를 만든 사용자는 그 금고의 유일한
OWNER가 된다.

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

연결 해제는 되돌리기 기능이 아니다. 종료된 Binding을 다시 살리지 않고,
재등록 시 증가한 generation의 새 Binding을 만든다.

### 상태 전이 요약

| 상황 | 물리 기기 | 기존 Binding | 금고와 영상 | 다음 등록 |
|---|---|---|---|---|
| 활성 연결 | `ONLINE` 또는 `OFFLINE` | `ACTIVE` | 촬영·라이브·과거 영상 사용 | 등록 불가 |
| OWNER가 연결 해제 | `UNCLAIMED` | `DISCONNECTED` | 그대로 유지, 신규 촬영만 중단 | 기존 금고 또는 새 금고를 선택 |
| 기존 금고로 재등록 | `ONLINE` 또는 `OFFLINE` | 새 generation `ACTIVE` | 선택한 기존 금고에 신규 영상 귀속 | 활성 중 변경 불가 |
| 새 금고로 재등록 | `ONLINE` 또는 `OFFLINE` | 새 generation `ACTIVE` | 기존 금고와 완전히 분리 | 활성 중 변경 불가 |

등록 코드는 `UNCLAIMED` 기기에만 발급한다. `ONLINE`과 `OFFLINE`은
활성 Binding이 있는 기기의 접속 상태 차이일 뿐이므로 새 등록 대상이
아니다.

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
- MEMBER가 회수되거나 탈퇴하면 해당 금고의 과거 영상 접근 권한도
  즉시 잃는다. 영상 자체와 다른 구성원의 권한은 유지된다.
- 마지막 기기를 연결 해제해도 OWNER와 MEMBER는 자동 탈퇴하지 않는다.

### 중고 양도

판매자의 Binding과 구매자의 Binding은 서로 다른 generation이다.
기존 영상의 `vault_id`는 판매자 금고에 고정되므로 구매자에게 이전되지
않는다. 물리 기기는 `UNCLAIMED` 상태에서 구매자의 금고에 새로 Binding
된다.

## 4. 접근 제어 불변식

1. 영상 조회·수정·삭제 권한은 `vault_memberships`로 판단한다.
2. 기기 한 대에는 활성 Binding이 최대 한 건이다.
3. 정상 서비스 흐름에서 영상의 `vault_id`는 생성 후 변경하지 않는다.
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
- V29/V30 이전에 이미 해제된 기기는 과거 상태인 `REVOKED`로 남을 수
  있다. 새 해제 로직의 `UNCLAIMED` 전이는 배포 이후 정상 해제 요청부터
  적용되며, 과거 행을 임의로 현재 상태처럼 바꾸지 않는다.

## 7. 삭제 영상 운영 복구 절차

오브젝트 스토리지에서 삭제가 끝난 영상은 데이터베이스 상태만 바꿔서는
복구되지 않는다. 앱에는 항목이 보이더라도 재생 파일이 없어 실패하므로
반드시 다음 순서를 지킨다.

1. V29/V30 적용 여부와 대상 금고의 단일 OWNER를 확인한다.
2. 복구 직전 PostgreSQL과 MinIO의 새 전체 백업을 만들고 체크섬을
   검증한다.
3. 삭제 전 백업에서 대상 영상 객체만 MinIO에 복원한다.
4. 모든 대상 객체가 조회되고 실제 바이트를 읽을 수 있는지 확인한다.
5. 하나의 데이터베이스 트랜잭션에서 대상 영상만 새 `vault_id`에
   연결하고 `READY`로 전환한다.
6. 갱신 행 수가 예상 개수와 정확히 같은지 확인한 뒤 커밋한다.
7. API 목록 조회와 스트리밍 응답, 실제 앱 재생을 순서대로 검증한다.

복구 시 `device_id`는 촬영 당시 물리 기기 이력이므로 유지하고,
`created_by`도 임의로 변경하지 않는다. 사용자 접근 경계만
`vault_id`로 옮기며 `delete_requested_at`, `deleted_at`, `deleted_by`를
비운다. 이 작업은 일반 서비스 기능이 아니라 백업에 실제 객체가 존재할
때만 수행하는 승인된 운영 복구 예외다.

```sql
BEGIN;

UPDATE videos
SET vault_id = :target_vault_id,
    status = 'READY',
    delete_requested_at = NULL,
    deleted_at = NULL,
    deleted_by = NULL,
    updated_at = now()
WHERE device_id = :source_device_id
  AND status = 'DELETED';

-- 예상 개수와 다르면 COMMIT하지 않는다.
SELECT count(*)
FROM videos
WHERE vault_id = :target_vault_id
  AND device_id = :source_device_id
  AND status = 'READY';

COMMIT;
```

## 8. 구성원 조회 장애와 회귀 방지

`/api/vaults/{vaultId}/members`는 여러 테이블을 조인한 결과를
`MembershipRow`에 매핑한다. PostgreSQL의 `joined_at`은 JDBC에서
`Timestamp`로 반환되므로, MyBatis가 record의 여러 생성자 중 하나를
추측하게 두면 운영 환경에서 생성자를 찾지 못해 500 응답이 발생할 수
있다.

- record의 정식 생성자에 `@AutomapConstructor`를 지정한다.
- 모든 구성원 조회 쿼리의 projection을 같은 9개 컬럼과 같은 타입으로
  통일한다.
- 실제 PostgreSQL과 MyBatis를 사용하는 통합 테스트로 OWNER/MEMBER
  조회를 검증한다.
- Flyway 통합 테스트와 동시에 실행될 때 스키마가 충돌하지 않도록
  매퍼 통합 테스트는 전용 스키마를 사용한다.

Flutter는 Vault·구성원·기기 정보를 묶어 초기화하므로 구성원 API 한
곳의 500도 화면에서 기기 `OFFLINE`이나 빈 목록처럼 보일 수 있다.
이 경우 물리 기기 상태만 추정하지 말고 해당 시각의 API별 응답과 Backend
로그를 함께 확인한다.

## 9. Vault 쓰기 API 500과 UUID 스칼라 매핑

MyBatis에는 `java.util.UUID`용 기본 TypeHandler가 없다. uuid 컬럼을
record 필드로 읽는 것은 결과 매핑을 거치므로 동작하지만, 단일 uuid
컬럼을 `Optional<UUID>` 스칼라로 반환하면 MyBatis가 UUID를 빈으로 보고
생성을 시도해 private `UUID(byte[])` 생성자에서 실패한다.

이 형태의 매퍼는 Vault 도입과 함께 처음 생겼다.

- `InvitationMapper.findFirstActiveDeviceId`
- `VaultMapper.lockActiveVaultId`

앞의 것은 초대 생성·초대 취소·구성원 회수·소유권 양도에서, 뒤의 것은
기기 연결 해제에서 호출된다. 권한과 중복 검사는 이 호출보다 먼저
끝나므로 미가입 이메일은 404, 기존 구성원은 409를 정상적으로 받는다.
정상 초대 대상만 이 지점까지 도달해 500이 되므로, 증상이 "특정 계정만
초대가 안 된다"로 보인다.

조치와 회귀 방지:

- `UuidTypeHandler`를 `ConfigurationCustomizer`로 전역 등록한다.
- 등록 여부를 `MyBatisConfigTest`로 검증한다.
- `VaultInvitationMapperIntegrationTest`가 실제 PostgreSQL과 Flyway
  스키마에서 초대 삽입부터 조회까지를 통과시킨다.
- 새 매퍼가 스칼라를 반환할 때는 record 필드 매핑과 다른 경로임을
  전제하고 통합 테스트를 함께 추가한다.

검증 조건: 로컬 Windows, Testcontainers `postgres:16-alpine`, Gradle
`test` 태스크 전체 158개 통과(스킵 0).

## 10. 2026-07-29 운영 반영 및 검증 기록

- Vault 수명주기 변경을 역할별 develop과 `master`에 병합하고 Backend
  운영 배포를 완료했다.
- V29와 V30이 운영 데이터베이스에 적용된 것을 확인했다.
- 구성원 조회 생성자 매핑 긴급 수정도 `master` 병합, CI, 운영 재배포를
  완료했다.
- 복구 직전 PostgreSQL·MinIO 전체 백업과 체크섬을 생성했다.
- 삭제 전 백업에서 영상 객체 20개를 복원해 각 객체의 조회와 바이트
  읽기를 확인했다.
- 데이터베이스 영상 20개를 대상 금고에 연결하고 모두 `READY`인 것과
  대상 금고의 활성 OWNER가 정확히 한 명인 것을 확인했다.
- 서버와 데이터 수준 복구는 완료됐다. 최종 앱 목록·재생 확인은 대상
  계정으로 다시 로그인한 실제 기기에서 별도로 수행해야 한다.
