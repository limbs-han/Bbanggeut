ALTER TABLE device_credentials
    ADD COLUMN IF NOT EXISTS purpose varchar(20) NOT NULL DEFAULT 'OPERATING';

ALTER TABLE device_credentials
    DROP CONSTRAINT IF EXISTS ck_device_credentials_purpose;

ALTER TABLE device_credentials
    ADD CONSTRAINT ck_device_credentials_purpose
        CHECK (purpose IN ('BOOTSTRAP', 'OPERATING'));

-- Credentials created before lifecycle enforcement were effectively permanent.
-- Give them a bounded migration window instead of silently keeping them forever.
UPDATE device_credentials
   SET expires_at = now() + interval '30 days'
 WHERE status = 'ACTIVE'
   AND expires_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_device_credentials_purpose_expiry
    ON device_credentials (device_id, purpose, expires_at)
    WHERE status = 'ACTIVE';
