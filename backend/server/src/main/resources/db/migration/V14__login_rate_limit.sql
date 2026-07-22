CREATE TABLE IF NOT EXISTS auth_login_attempts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email_hash char(64) NOT NULL,
    ip_hash char(64) NOT NULL,
    succeeded boolean NOT NULL DEFAULT false,
    attempted_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_auth_login_attempt_email_hash CHECK (email_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_auth_login_attempt_ip_hash CHECK (ip_hash ~ '^[0-9a-f]{64}$')
);

CREATE INDEX IF NOT EXISTS ix_auth_login_attempt_email_failure
    ON auth_login_attempts (email_hash, attempted_at DESC)
    WHERE succeeded = false;
CREATE INDEX IF NOT EXISTS ix_auth_login_attempt_ip_failure
    ON auth_login_attempts (ip_hash, attempted_at DESC)
    WHERE succeeded = false;
