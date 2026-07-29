DO $$
BEGIN
    CREATE TYPE vault_status AS ENUM ('ACTIVE', 'CLOSING', 'CLOSED');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE device_binding_status AS ENUM (
        'ACTIVE', 'DISCONNECTED', 'REPLACED', 'SOLD', 'LOST', 'BROKEN'
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS memory_vaults (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name varchar(80) NOT NULL,
    status vault_status NOT NULL DEFAULT 'ACTIVE',
    retention_days integer NOT NULL DEFAULT 30
        CHECK (retention_days BETWEEN 1 AND 3650),
    subscription_active boolean NOT NULL DEFAULT false,
    subscription_grace_until timestamptz,
    closure_scheduled_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_memory_vaults_name
        CHECK (char_length(btrim(name)) BETWEEN 1 AND 80)
);

CREATE TABLE IF NOT EXISTS vault_memberships (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    vault_id uuid NOT NULL REFERENCES memory_vaults(id) ON DELETE RESTRICT,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    role device_role NOT NULL DEFAULT 'MEMBER',
    status membership_status NOT NULL DEFAULT 'ACTIVE',
    joined_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    revoked_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_vault_memberships_vault_user UNIQUE (vault_id, user_id),
    CONSTRAINT ck_vault_memberships_revocation CHECK (
        (status = 'ACTIVE' AND revoked_at IS NULL)
        OR (status = 'REVOKED' AND revoked_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_vault_memberships_one_active_owner
    ON vault_memberships (vault_id)
    WHERE role = 'OWNER' AND status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS ix_vault_memberships_user_active
    ON vault_memberships (user_id, vault_id)
    WHERE status = 'ACTIVE';

CREATE TABLE IF NOT EXISTS device_bindings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    vault_id uuid NOT NULL REFERENCES memory_vaults(id) ON DELETE RESTRICT,
    generation integer NOT NULL CHECK (generation > 0),
    status device_binding_status NOT NULL DEFAULT 'ACTIVE',
    bound_at timestamptz NOT NULL DEFAULT now(),
    ended_at timestamptz,
    ended_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_device_bindings_generation UNIQUE (device_id, generation),
    CONSTRAINT ck_device_bindings_end CHECK (
        (status = 'ACTIVE' AND ended_at IS NULL)
        OR (status <> 'ACTIVE' AND ended_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_device_bindings_one_active_device
    ON device_bindings (device_id)
    WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS ix_device_bindings_vault_active
    ON device_bindings (vault_id, bound_at DESC)
    WHERE status = 'ACTIVE';

-- Every legacy device that has account data becomes its own initial vault.
-- Reusing the UUID across different tables is deliberate: it makes the
-- migration deterministic without changing the public device identifier.
INSERT INTO memory_vaults (
    id, name, status, retention_days, subscription_active,
    subscription_grace_until, created_at, updated_at
)
SELECT d.id, d.name, 'ACTIVE', d.retention_days, d.subscription_active,
       d.subscription_grace_until, d.created_at, now()
  FROM devices d
 WHERE d.claimed_at IS NOT NULL
    OR EXISTS (SELECT 1 FROM device_memberships m WHERE m.device_id = d.id)
    OR EXISTS (SELECT 1 FROM videos v WHERE v.device_id = d.id)
ON CONFLICT (id) DO NOTHING;

-- Active installations keep their current OWNER/MEMBER set.
INSERT INTO vault_memberships (
    vault_id, user_id, role, status, joined_at, created_at, updated_at
)
SELECT m.device_id, m.user_id, m.role, 'ACTIVE', m.joined_at, m.created_at, now()
  FROM device_memberships m
  JOIN devices d ON d.id = m.device_id
 WHERE m.status = 'ACTIVE'
   AND d.status IN ('ONLINE', 'OFFLINE')
ON CONFLICT (vault_id, user_id) DO UPDATE
    SET role = EXCLUDED.role, status = 'ACTIVE', revoked_at = NULL,
        revoked_by = NULL, updated_at = now();

-- A previously released device may already have lost every active membership.
-- Restore only its former OWNER, never historical members who might have been
-- intentionally removed before release.
INSERT INTO vault_memberships (
    vault_id, user_id, role, status, joined_at, created_at, updated_at
)
SELECT d.id, d.claimed_by, 'OWNER', 'ACTIVE',
       COALESCE(d.claimed_at, d.created_at), d.created_at, now()
  FROM devices d
 WHERE d.status = 'REVOKED' AND d.claimed_by IS NOT NULL
ON CONFLICT (vault_id, user_id) DO UPDATE
    SET role = 'OWNER', status = 'ACTIVE', revoked_at = NULL,
        revoked_by = NULL, updated_at = now();

INSERT INTO device_bindings (
    device_id, vault_id, generation, status, bound_at, ended_at,
    created_at, updated_at
)
SELECT d.id, d.id, 1,
       CASE WHEN d.status IN ('ONLINE', 'OFFLINE')
            THEN 'ACTIVE'::device_binding_status
            ELSE 'DISCONNECTED'::device_binding_status END,
       COALESCE(d.claimed_at, d.created_at),
       CASE WHEN d.status = 'REVOKED'
            THEN COALESCE(d.revoked_at, d.updated_at) ELSE NULL END,
       d.created_at, now()
  FROM devices d
 WHERE EXISTS (SELECT 1 FROM memory_vaults v WHERE v.id = d.id)
ON CONFLICT (device_id, generation) DO NOTHING;

ALTER TABLE videos ADD COLUMN IF NOT EXISTS vault_id uuid
    REFERENCES memory_vaults(id) ON DELETE RESTRICT;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS device_binding_id uuid
    REFERENCES device_bindings(id) ON DELETE SET NULL;

UPDATE videos v
   SET vault_id = v.device_id
 WHERE v.vault_id IS NULL;

UPDATE videos v
   SET device_binding_id = b.id
  FROM device_bindings b
 WHERE v.device_binding_id IS NULL
   AND b.device_id = v.device_id
   AND b.generation = 1;

ALTER TABLE videos ALTER COLUMN vault_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS ix_videos_vault_created
    ON videos (vault_id, created_at DESC, id DESC);

-- The physical device row is stable across disconnect/reconnect cycles.
-- Claim state is operational state only; vaults own content and membership.
ALTER TABLE devices DROP CONSTRAINT IF EXISTS ck_devices_claim_state;
ALTER TABLE devices ADD CONSTRAINT ck_devices_claim_state CHECK (
    (status = 'UNCLAIMED' AND claimed_at IS NULL
        AND claimed_by IS NULL AND revoked_at IS NULL)
    OR (status IN ('ONLINE', 'OFFLINE') AND claimed_at IS NOT NULL
        AND claimed_by IS NOT NULL AND revoked_at IS NULL)
    OR (status = 'REVOKED' AND revoked_at IS NOT NULL)
);
