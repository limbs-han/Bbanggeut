DO $$
BEGIN
    CREATE TYPE device_role AS ENUM ('OWNER', 'MEMBER');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE membership_status AS ENUM ('ACTIVE', 'REVOKED');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE device_status AS ENUM ('UNCLAIMED', 'ONLINE', 'OFFLINE', 'REVOKED');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS devices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    serial_number varchar(80) NOT NULL,
    product_code_hash char(64) NOT NULL,
    name varchar(80) NOT NULL DEFAULT 'William James Camera',
    model varchar(80) NOT NULL DEFAULT 'WJ-DEV-01',
    firmware_version varchar(40),
    status device_status NOT NULL DEFAULT 'UNCLAIMED',
    retention_days integer NOT NULL DEFAULT 30 CHECK (retention_days BETWEEN 1 AND 3650),
    registration_mode_expires_at timestamptz,
    product_code_retired_at timestamptz,
    claimed_at timestamptz,
    claimed_by uuid REFERENCES users(id) ON DELETE SET NULL,
    last_seen_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_devices_serial_number UNIQUE (serial_number),
    CONSTRAINT uq_devices_product_code_hash UNIQUE (product_code_hash),
    CONSTRAINT ck_devices_product_code_hash CHECK (product_code_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_devices_name CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
    CONSTRAINT ck_devices_claim_state CHECK (
        (status = 'UNCLAIMED' AND claimed_at IS NULL AND claimed_by IS NULL AND revoked_at IS NULL AND product_code_retired_at IS NULL)
        OR (status IN ('ONLINE', 'OFFLINE') AND claimed_at IS NOT NULL AND claimed_by IS NOT NULL AND revoked_at IS NULL AND product_code_retired_at IS NOT NULL)
        OR (status = 'REVOKED' AND claimed_at IS NOT NULL AND revoked_at IS NOT NULL AND product_code_retired_at IS NOT NULL)
    )
);

-- Compatibility columns for databases created by the initial skeleton.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS firmware_version varchar(40);
ALTER TABLE devices ADD COLUMN IF NOT EXISTS revoked_at timestamptz;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE devices ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE devices ALTER COLUMN serial_number TYPE varchar(80);
UPDATE devices SET model = 'WJ-DEV-01' WHERE model IS NULL;
ALTER TABLE devices ALTER COLUMN model SET DEFAULT 'WJ-DEV-01';
ALTER TABLE devices ALTER COLUMN model SET NOT NULL;
ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_status_check;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name = 'devices'
           AND column_name = 'status'
           AND udt_name <> 'device_status'
    ) THEN
        ALTER TABLE devices ALTER COLUMN status DROP DEFAULT;
        ALTER TABLE devices ALTER COLUMN status TYPE device_status
            USING (CASE status::text
                WHEN 'ACTIVE' THEN 'OFFLINE'
                WHEN 'DISABLED' THEN 'REVOKED'
                ELSE status::text
            END)::device_status;
        ALTER TABLE devices ALTER COLUMN status SET DEFAULT 'UNCLAIMED';
    END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS ux_devices_serial_number ON devices (serial_number);
CREATE UNIQUE INDEX IF NOT EXISTS ux_devices_product_code_hash ON devices (product_code_hash);
CREATE INDEX IF NOT EXISTS ix_devices_status ON devices (status);
CREATE INDEX IF NOT EXISTS ix_devices_last_seen ON devices (last_seen_at DESC)
    WHERE status IN ('ONLINE', 'OFFLINE');

CREATE TABLE IF NOT EXISTS device_memberships (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    role device_role NOT NULL DEFAULT 'MEMBER',
    status membership_status NOT NULL DEFAULT 'ACTIVE',
    joined_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    revoked_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_device_memberships_device_user UNIQUE (device_id, user_id),
    CONSTRAINT ck_device_memberships_revocation CHECK (
        (status = 'ACTIVE' AND revoked_at IS NULL)
        OR (status = 'REVOKED' AND revoked_at IS NOT NULL)
    )
);

ALTER TABLE device_memberships ADD COLUMN IF NOT EXISTS revoked_by uuid REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE device_memberships ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE device_memberships ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE device_memberships DROP CONSTRAINT IF EXISTS device_memberships_role_check;
ALTER TABLE device_memberships DROP CONSTRAINT IF EXISTS device_memberships_status_check;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'device_memberships'
           AND column_name = 'role' AND udt_name <> 'device_role'
    ) THEN
        ALTER TABLE device_memberships ALTER COLUMN role DROP DEFAULT;
        ALTER TABLE device_memberships ALTER COLUMN role TYPE device_role USING role::text::device_role;
        ALTER TABLE device_memberships ALTER COLUMN role SET DEFAULT 'MEMBER';
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'device_memberships'
           AND column_name = 'status' AND udt_name <> 'membership_status'
    ) THEN
        ALTER TABLE device_memberships ALTER COLUMN status DROP DEFAULT;
        ALTER TABLE device_memberships ALTER COLUMN status TYPE membership_status USING status::text::membership_status;
        ALTER TABLE device_memberships ALTER COLUMN status SET DEFAULT 'ACTIVE';
    END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS ux_device_memberships_device_user
    ON device_memberships (device_id, user_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_device_memberships_one_active_owner
    ON device_memberships (device_id)
    WHERE role = 'OWNER' AND status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS ix_device_memberships_user_active
    ON device_memberships (user_id, device_id)
    WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS ix_device_memberships_device_active
    ON device_memberships (device_id, role, joined_at)
    WHERE status = 'ACTIVE';

CREATE OR REPLACE FUNCTION prevent_device_membership_identity_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.device_id <> OLD.device_id OR NEW.user_id <> OLD.user_id THEN
        RAISE EXCEPTION 'device membership device_id and user_id are immutable';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_device_memberships_identity_immutable ON device_memberships;
CREATE TRIGGER trg_device_memberships_identity_immutable
BEFORE UPDATE ON device_memberships
FOR EACH ROW EXECUTE FUNCTION prevent_device_membership_identity_change();

CREATE OR REPLACE FUNCTION ensure_claimed_device_has_one_owner()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    affected_device_id uuid;
    owner_count integer;
    current_status device_status;
BEGIN
    IF TG_TABLE_NAME = 'devices' THEN
        affected_device_id := NEW.id;
    ELSIF TG_OP = 'DELETE' THEN
        affected_device_id := OLD.device_id;
    ELSE
        affected_device_id := NEW.device_id;
    END IF;

    SELECT status INTO current_status FROM devices WHERE id = affected_device_id;
    IF current_status IN ('ONLINE', 'OFFLINE') THEN
        SELECT count(*) INTO owner_count
          FROM device_memberships
         WHERE device_id = affected_device_id AND role = 'OWNER' AND status = 'ACTIVE';
        IF owner_count <> 1 THEN
            RAISE EXCEPTION 'claimed device % must have exactly one active OWNER', affected_device_id;
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_device_memberships_exactly_one_owner ON device_memberships;
CREATE CONSTRAINT TRIGGER trg_device_memberships_exactly_one_owner
AFTER INSERT OR UPDATE OR DELETE ON device_memberships
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ensure_claimed_device_has_one_owner();

DROP TRIGGER IF EXISTS trg_devices_exactly_one_owner ON devices;
CREATE CONSTRAINT TRIGGER trg_devices_exactly_one_owner
AFTER INSERT OR UPDATE ON devices
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ensure_claimed_device_has_one_owner();
