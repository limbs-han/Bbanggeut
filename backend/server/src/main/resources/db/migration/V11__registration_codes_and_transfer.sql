-- Screen-displayed one-time registration codes replace the printed product code,
-- and ownership transfer is modeled as "revoke the old device row, create a fresh
-- UNCLAIMED row for the same serial".

-- 1) Drop the static product-code columns and the constraints that reference them.
ALTER TABLE devices DROP CONSTRAINT IF EXISTS ck_devices_claim_state;
ALTER TABLE devices DROP CONSTRAINT IF EXISTS uq_devices_product_code_hash;
ALTER TABLE devices DROP CONSTRAINT IF EXISTS ck_devices_product_code_hash;
DROP INDEX IF EXISTS ux_devices_product_code_hash;
ALTER TABLE devices DROP COLUMN IF EXISTS product_code_hash;
ALTER TABLE devices DROP COLUMN IF EXISTS product_code_retired_at;

ALTER TABLE devices ADD CONSTRAINT ck_devices_claim_state CHECK (
    (status = 'UNCLAIMED' AND claimed_at IS NULL AND claimed_by IS NULL AND revoked_at IS NULL)
    OR (status IN ('ONLINE', 'OFFLINE') AND claimed_at IS NOT NULL AND claimed_by IS NOT NULL AND revoked_at IS NULL)
    OR (status = 'REVOKED' AND claimed_at IS NOT NULL AND revoked_at IS NOT NULL)
);

-- 2) Serial numbers stay unique among live rows only, so a transfer can create a
--    new UNCLAIMED row while the revoked row keeps the history.
ALTER TABLE devices DROP CONSTRAINT IF EXISTS uq_devices_serial_number;
DROP INDEX IF EXISTS ux_devices_serial_number;
CREATE UNIQUE INDEX IF NOT EXISTS ux_devices_serial_number_live
    ON devices (serial_number)
    WHERE status <> 'REVOKED';

-- 3) One-time registration codes. The plaintext exists only on the device screen
--    and in the issue response; the hash uniqueness guarantees that a submitted
--    code identifies exactly one device.
CREATE TABLE IF NOT EXISTS registration_codes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    code_hash char(64) NOT NULL,
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    used_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_registration_codes_code_hash UNIQUE (code_hash),
    CONSTRAINT ck_registration_codes_code_hash CHECK (code_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_registration_codes_usage CHECK (used_at IS NULL OR used_by IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ix_registration_codes_device
    ON registration_codes (device_id, created_at DESC);

-- 4) The app no longer sends a serial number, so claim attempts are rate limited
--    per account and per IP only.
DROP INDEX IF EXISTS ix_claim_attempt_serial_failure;
ALTER TABLE device_claim_attempts DROP CONSTRAINT IF EXISTS ck_claim_attempt_serial_hash;
ALTER TABLE device_claim_attempts DROP COLUMN IF EXISTS serial_fingerprint;
