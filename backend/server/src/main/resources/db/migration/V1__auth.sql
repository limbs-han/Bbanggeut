CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
    CREATE TYPE user_status AS ENUM ('ACTIVE', 'LOCKED', 'WITHDRAWN');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email varchar(320) NOT NULL,
    password_hash varchar(255) NOT NULL,
    display_name varchar(60) NOT NULL,
    status user_status NOT NULL DEFAULT 'ACTIVE',
    token_version integer NOT NULL DEFAULT 0 CHECK (token_version >= 0),
    last_login_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    CONSTRAINT ck_users_email_normalized CHECK (email = lower(btrim(email))),
    CONSTRAINT ck_users_email_shape CHECK (position('@' in email) > 1),
    CONSTRAINT ck_users_display_name CHECK (char_length(btrim(display_name)) BETWEEN 1 AND 60),
    CONSTRAINT ck_users_deleted_status CHECK (deleted_at IS NULL OR status = 'WITHDRAWN')
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_users_email_active
    ON users (lower(email))
    WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS auth_sessions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    refresh_token_hash char(64) NOT NULL,
    client_name varchar(120),
    user_agent varchar(512),
    ip_address inet,
    expires_at timestamptz NOT NULL,
    last_used_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_auth_sessions_hash CHECK (refresh_token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_auth_sessions_expiry CHECK (expires_at > created_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_auth_sessions_refresh_hash
    ON auth_sessions (refresh_token_hash);

CREATE INDEX IF NOT EXISTS ix_auth_sessions_user_active
    ON auth_sessions (user_id, expires_at DESC)
    WHERE revoked_at IS NULL;
