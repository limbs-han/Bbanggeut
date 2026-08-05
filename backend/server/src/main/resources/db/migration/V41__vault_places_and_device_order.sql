-- 장소 배치와 기기 순서를 서버로 옮긴다.
--
-- 지금까지 앱이 Secure Storage에 JSON 한 덩이로 들고 있었다
-- (`bbanggeut_device_places_v1_{userId}`). 폰을 바꾸거나 앱을 다시 깔면
-- 사라졌고, 가족끼리 공유되지 않아 아빠 폰에서 "거실/안방"으로 나눠 놓아도
-- 엄마 폰에는 전부 한 곳에 몰려 보였다.
--
-- 무엇을 공유하고 무엇을 사람마다 둘지는 성질이 다르다.
--
-- - 장소 이름과 기기가 어느 장소에 있는지는 **집의 사실**이다. 가족이 함께
--   본다. 거실 홈캠은 누가 봐도 거실에 있다.
-- - 기기를 어떤 순서로 볼지는 **보기 취향**이다. 사람마다 다르게 둔다.
--
-- 어느 장소를 지금 보고 있는지(selectedPlace)는 화면 상태라 서버에 두지 않고
-- 앱에 남긴다.

-- 금고의 장소 이름 목록.
--
-- 기기를 배정하지 않은 빈 장소도 남아야 한다 — 앱은 장소를 먼저 만들고 나중에
-- 기기를 옮기므로, 배정에서 이름을 유도하면 방금 만든 장소가 사라진다.
CREATE TABLE IF NOT EXISTS vault_places (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    vault_id uuid NOT NULL REFERENCES memory_vaults(id) ON DELETE CASCADE,
    name varchar(15) NOT NULL,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_vault_places_name UNIQUE (vault_id, name),
    CONSTRAINT ck_vault_places_name CHECK (char_length(btrim(name)) BETWEEN 1 AND 15)
);

-- 기기가 어느 장소에 있나. 금고 공통이다.
--
-- place_name을 vault_places로 외래키 걸지 않은 이유는 장소 이름을 바꾸거나
-- 지울 때 배정을 함께 정리하는 순서를 서비스가 한 트랜잭션으로 관리하기
-- 때문이다. 이름이 사라진 배정은 앱이 첫 장소로 읽는다(기존 동작과 같다).
CREATE TABLE IF NOT EXISTS vault_device_places (
    vault_id uuid NOT NULL REFERENCES memory_vaults(id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    place_name varchar(15) NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (vault_id, device_id)
);

-- 사람마다 다른 기기 순서. 금고 단위로 둔다(앱의 기존 범위와 같다).
CREATE TABLE IF NOT EXISTS user_device_orders (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    vault_id uuid NOT NULL REFERENCES memory_vaults(id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    sort_order integer NOT NULL,
    PRIMARY KEY (user_id, vault_id, device_id)
);

CREATE INDEX IF NOT EXISTS ix_user_device_orders_scope
    ON user_device_orders (user_id, vault_id, sort_order);
