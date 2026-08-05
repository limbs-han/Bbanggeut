-- 일정을 사람 소유에서 금고 공유로 옮긴다.
--
-- 지금까지 user_schedules는 user_id 하나만 보고 조회·수정·삭제했다. 가족
-- 구성원이 서로의 기념일을 볼 수 없었고, 같은 날을 각자 따로 적어야 했다.
--
-- vault_id를 더하고 user_id는 "작성자"로 남긴다. 수정·삭제 권한을 작성자와
-- 금고 OWNER에게 주려면 누가 적었는지가 계속 필요하다.
--
-- 무중단 배포 규칙에 맞춰 가산적으로만 바꾼다. NOT NULL을 걸지 않는 이유는
-- 새 슬롯이 이 마이그레이션을 적용하는 동안 구 슬롯이 vault_id 없이 INSERT를
-- 계속하기 때문이다. 금고가 없는 사용자의 일정도 NULL로 남아 개인 일정으로
-- 계속 보인다.
ALTER TABLE user_schedules
    ADD COLUMN IF NOT EXISTS vault_id uuid REFERENCES memory_vaults(id) ON DELETE CASCADE;

-- 기존 일정을 작성자의 금고로 옮긴다. 여러 금고에 속한 사용자는 OWNER인
-- 금고를 먼저 고르고, 없으면 가장 먼저 참여한 금고로 보낸다 — 임의로 흩어지지
-- 않게 순서를 고정한다.
UPDATE user_schedules s
   SET vault_id = pick.vault_id
  FROM (
    SELECT DISTINCT ON (m.user_id) m.user_id, m.vault_id
      FROM vault_memberships m
     WHERE m.status = 'ACTIVE'
     ORDER BY m.user_id,
              CASE WHEN m.role = 'OWNER' THEN 0 ELSE 1 END,
              m.joined_at,
              m.vault_id
  ) AS pick
 WHERE s.vault_id IS NULL
   AND s.user_id = pick.user_id;

-- 캘린더는 금고의 한 달을 훑는다.
CREATE INDEX IF NOT EXISTS ix_user_schedules_vault_date
    ON user_schedules (vault_id, schedule_date);
