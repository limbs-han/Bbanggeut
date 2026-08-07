DO $$
BEGIN
    CREATE TYPE credential_type AS ENUM ('CERTIFICATE', 'TOKEN_HASH');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE credential_status AS ENUM ('ACTIVE', 'REVOKED', 'EXPIRED');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS device_claim_attempts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    serial_fingerprint char(64) NOT NULL,
    ip_hash char(64) NOT NULL,
    succeeded boolean NOT NULL DEFAULT false,
    attempted_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_claim_attempt_serial_hash CHECK (serial_fingerprint ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_claim_attempt_ip_hash CHECK (ip_hash ~ '^[0-9a-f]{64}$')
);

CREATE INDEX IF NOT EXISTS ix_claim_attempt_user_failure
    ON device_claim_attempts (user_id, attempted_at DESC)
    WHERE succeeded = false;
CREATE INDEX IF NOT EXISTS ix_claim_attempt_serial_failure
    ON device_claim_attempts (serial_fingerprint, attempted_at DESC)
    WHERE succeeded = false;
CREATE INDEX IF NOT EXISTS ix_claim_attempt_ip_failure
    ON device_claim_attempts (ip_hash, attempted_at DESC)
    WHERE succeeded = false;

CREATE TABLE IF NOT EXISTS device_credentials (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    key_id varchar(100) NOT NULL,
    credential_type credential_type NOT NULL,
    public_key_pem text,
    secret_hash char(64),
    status credential_status NOT NULL DEFAULT 'ACTIVE',
    issued_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_device_credentials_key_id UNIQUE (key_id),
    CONSTRAINT ck_device_credentials_material CHECK (
        (credential_type = 'CERTIFICATE' AND public_key_pem IS NOT NULL AND secret_hash IS NULL)
        OR (credential_type = 'TOKEN_HASH' AND public_key_pem IS NULL AND secret_hash IS NOT NULL)
    ),
    CONSTRAINT ck_device_credentials_hash CHECK (secret_hash IS NULL OR secret_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_device_credentials_expiry CHECK (expires_at IS NULL OR expires_at > issued_at),
    CONSTRAINT ck_device_credentials_revocation CHECK (
        (status = 'REVOKED' AND revoked_at IS NOT NULL)
        OR (status <> 'REVOKED' AND revoked_at IS NULL)
    )
);

-- Compatibility for the initial skeleton credential table.
ALTER TABLE device_credentials ADD COLUMN IF NOT EXISTS public_key_pem text;
ALTER TABLE device_credentials ADD COLUMN IF NOT EXISTS secret_hash char(64);
ALTER TABLE device_credentials ADD COLUMN IF NOT EXISTS issued_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE device_credentials ADD COLUMN IF NOT EXISTS revoked_at timestamptz;
ALTER TABLE device_credentials ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE device_credentials DROP CONSTRAINT IF EXISTS device_credentials_credential_type_check;
ALTER TABLE device_credentials DROP CONSTRAINT IF EXISTS device_credentials_status_check;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'device_credentials'
           AND column_name = 'credential_hash'
    ) THEN
        UPDATE device_credentials SET secret_hash = credential_hash WHERE secret_hash IS NULL;
        ALTER TABLE device_credentials DROP COLUMN credential_hash;
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'device_credentials'
           AND column_name = 'credential_type' AND udt_name <> 'credential_type'
    ) THEN
        ALTER TABLE device_credentials ALTER COLUMN credential_type DROP DEFAULT;
        ALTER TABLE device_credentials ALTER COLUMN credential_type TYPE credential_type
            USING (CASE credential_type::text
                WHEN 'TOKEN' THEN 'TOKEN_HASH'
                WHEN 'CERT' THEN 'CERTIFICATE'
                ELSE credential_type::text
            END)::credential_type;
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'device_credentials'
           AND column_name = 'status' AND udt_name <> 'credential_status'
    ) THEN
        ALTER TABLE device_credentials ALTER COLUMN status DROP DEFAULT;
        ALTER TABLE device_credentials ALTER COLUMN status TYPE credential_status
            USING status::text::credential_status;
        ALTER TABLE device_credentials ALTER COLUMN status SET DEFAULT 'ACTIVE';
    END IF;
END
$$;

CREATE UNIQUE INDEX IF NOT EXISTS ux_device_credentials_key_id ON device_credentials (key_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_device_credentials_one_active
    ON device_credentials (device_id)
    WHERE status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS ix_device_credentials_device_status
    ON device_credentials (device_id, status, expires_at);
