-- William James MVP database schema
-- Target: PostgreSQL 15+
-- Authorization boundary: one device. Users and devices have a many-to-many
-- relationship through device_memberships.
-- All timestamps are stored as UTC timestamptz values.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE user_status AS ENUM ('ACTIVE', 'LOCKED', 'WITHDRAWN');
CREATE TYPE device_role AS ENUM ('OWNER', 'EDITOR', 'VIEWER');
CREATE TYPE membership_status AS ENUM ('ACTIVE', 'REVOKED');
CREATE TYPE device_status AS ENUM ('UNCLAIMED', 'ONLINE', 'OFFLINE', 'REVOKED');
CREATE TYPE credential_type AS ENUM ('CERTIFICATE', 'TOKEN_HASH');
CREATE TYPE credential_status AS ENUM ('ACTIVE', 'REVOKED', 'EXPIRED');
CREATE TYPE invitation_status AS ENUM ('PENDING', 'ACCEPTED', 'EXPIRED', 'REVOKED');
CREATE TYPE video_source_type AS ENUM ('IOT_CAPTURE', 'USER_UPLOAD');
CREATE TYPE video_trigger_type AS ENUM ('LAUGHTER', 'WAKE_WORD', 'TOUCH', 'MANUAL', 'USER_UPLOAD');
CREATE TYPE video_status AS ENUM ('UPLOADING', 'PROCESSING', 'READY', 'FAILED', 'DELETING', 'DELETED');
CREATE TYPE audit_outcome AS ENUM ('SUCCESS', 'DENIED', 'FAILED');
CREATE TYPE audit_action AS ENUM (
    'MEMBER_INVITE',
    'MEMBER_REVOKE',
    'DEVICE_CLAIM',
    'DEVICE_UPDATE',
    'DEVICE_REVOKE',
    'VIDEO_LIST',
    'VIDEO_VIEW',
    'VIDEO_PLAY',
    'VIDEO_DOWNLOAD',
    'VIDEO_UPDATE',
    'VIDEO_DELETE',
    'STREAM_OPEN',
    'STREAM_HEARTBEAT',
    'STREAM_CLOSE'
);

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TABLE users (
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

CREATE UNIQUE INDEX ux_users_email_active
    ON users (lower(email))
    WHERE deleted_at IS NULL;

CREATE INDEX ix_users_status ON users (status) WHERE deleted_at IS NULL;

CREATE TABLE auth_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
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

CREATE UNIQUE INDEX ux_auth_sessions_refresh_hash ON auth_sessions (refresh_token_hash);
CREATE INDEX ix_auth_sessions_user_active
    ON auth_sessions (user_id, expires_at DESC)
    WHERE revoked_at IS NULL;

CREATE TABLE auth_login_attempts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email_hash char(64) NOT NULL,
    ip_hash char(64) NOT NULL,
    succeeded boolean NOT NULL DEFAULT false,
    attempted_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_auth_login_attempt_email_hash CHECK (email_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_auth_login_attempt_ip_hash CHECK (ip_hash ~ '^[0-9a-f]{64}$')
);

CREATE INDEX ix_auth_login_attempt_email_failure
    ON auth_login_attempts (email_hash, attempted_at DESC) WHERE succeeded = false;
CREATE INDEX ix_auth_login_attempt_ip_failure
    ON auth_login_attempts (ip_hash, attempted_at DESC) WHERE succeeded = false;

CREATE TABLE devices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    serial_number varchar(80) NOT NULL,
    name varchar(80) NOT NULL DEFAULT 'William James Camera',
    model varchar(80) NOT NULL DEFAULT 'WJ-DEV-01',
    firmware_version varchar(40),
    status device_status NOT NULL DEFAULT 'UNCLAIMED',
    retention_days integer NOT NULL DEFAULT 30 CHECK (retention_days BETWEEN 1 AND 3650),
    registration_mode_expires_at timestamptz,
    claimed_at timestamptz,
    claimed_by uuid REFERENCES users(id) ON DELETE SET NULL,
    last_seen_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_devices_name CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
    CONSTRAINT ck_devices_claim_state CHECK (
        (status = 'UNCLAIMED' AND claimed_at IS NULL AND claimed_by IS NULL AND revoked_at IS NULL)
        OR (status IN ('ONLINE', 'OFFLINE') AND claimed_at IS NOT NULL AND claimed_by IS NOT NULL AND revoked_at IS NULL)
        OR (status = 'REVOKED' AND claimed_at IS NOT NULL AND revoked_at IS NOT NULL)
    )
);

-- Ownership transfer creates a fresh UNCLAIMED row for the same physical device
-- (the released row stays REVOKED), so serial uniqueness applies to live rows only.
CREATE UNIQUE INDEX ux_devices_serial_number_live
    ON devices (serial_number)
    WHERE status <> 'REVOKED';

CREATE INDEX ix_devices_status ON devices (status);
CREATE INDEX ix_devices_last_seen ON devices (last_seen_at DESC) WHERE status IN ('ONLINE', 'OFFLINE');

-- Screen-displayed one-time registration codes replace the printed product code.
-- The device requests a code when it enters registration mode; the server generates
-- a CSPRNG code (8 chars, confusion-free uppercase+digit alphabet), stores only the
-- hash, and the app submits the code to claim the device. The plaintext code must be
-- unique among live codes so that a submitted code identifies exactly one device.
CREATE TABLE registration_codes (
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

CREATE INDEX ix_registration_codes_device ON registration_codes (device_id, created_at DESC);

CREATE TABLE device_memberships (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    role device_role NOT NULL DEFAULT 'VIEWER',
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

-- The partial unique index guarantees at most one active OWNER per device.
CREATE UNIQUE INDEX ux_device_memberships_one_active_owner
    ON device_memberships (device_id)
    WHERE role = 'OWNER' AND status = 'ACTIVE';

CREATE INDEX ix_device_memberships_user_active
    ON device_memberships (user_id, device_id)
    WHERE status = 'ACTIVE';

CREATE INDEX ix_device_memberships_device_active
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

CREATE TRIGGER trg_device_memberships_identity_immutable
BEFORE UPDATE ON device_memberships
FOR EACH ROW EXECUTE FUNCTION prevent_device_membership_identity_change();

-- Deferred constraint trigger guarantees that every claimed, non-revoked device
-- has exactly one active OWNER at commit time. Claim and ownership-transfer logic
-- must update the device and membership rows in the same transaction.
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

    SELECT status INTO current_status
      FROM devices
     WHERE id = affected_device_id;

    IF current_status IN ('ONLINE', 'OFFLINE') THEN
        SELECT count(*) INTO owner_count
          FROM device_memberships
         WHERE device_id = affected_device_id
           AND role = 'OWNER'
           AND status = 'ACTIVE';

        IF owner_count <> 1 THEN
            RAISE EXCEPTION 'claimed device % must have exactly one active OWNER', affected_device_id;
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_device_memberships_exactly_one_owner
AFTER INSERT OR UPDATE OR DELETE ON device_memberships
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ensure_claimed_device_has_one_owner();

CREATE CONSTRAINT TRIGGER trg_devices_exactly_one_owner
AFTER INSERT OR UPDATE ON devices
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION ensure_claimed_device_has_one_owner();

CREATE TABLE device_credentials (
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

CREATE UNIQUE INDEX ux_device_credentials_one_active
    ON device_credentials (device_id)
    WHERE status = 'ACTIVE';

CREATE INDEX ix_device_credentials_device_status
    ON device_credentials (device_id, status, expires_at);

CREATE TABLE invitations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    inviter_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    invitee_email varchar(320) NOT NULL,
    role device_role NOT NULL DEFAULT 'VIEWER',
    token_hash char(64) NOT NULL,
    status invitation_status NOT NULL DEFAULT 'PENDING',
    expires_at timestamptz NOT NULL,
    accepted_by uuid REFERENCES users(id) ON DELETE SET NULL,
    accepted_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_invitations_token_hash UNIQUE (token_hash),
    CONSTRAINT ck_invitations_email_normalized CHECK (invitee_email = lower(btrim(invitee_email))),
    CONSTRAINT ck_invitations_email_shape CHECK (position('@' in invitee_email) > 1),
    CONSTRAINT ck_invitations_non_owner_only CHECK (role IN ('EDITOR', 'VIEWER')),
    CONSTRAINT ck_invitations_token_hash CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_invitations_expiry CHECK (expires_at > created_at),
    CONSTRAINT ck_invitations_acceptance CHECK (
        (status = 'ACCEPTED' AND accepted_by IS NOT NULL AND accepted_at IS NOT NULL AND revoked_at IS NULL)
        OR (status = 'REVOKED' AND accepted_at IS NULL AND revoked_at IS NOT NULL)
        OR (status IN ('PENDING', 'EXPIRED') AND accepted_at IS NULL AND revoked_at IS NULL)
    )
);

CREATE UNIQUE INDEX ux_invitations_one_pending_per_email
    ON invitations (device_id, lower(invitee_email))
    WHERE status = 'PENDING';

CREATE INDEX ix_invitations_device_status ON invitations (device_id, status, created_at DESC);
CREATE INDEX ix_invitations_email_status ON invitations (lower(invitee_email), status, expires_at);

CREATE TABLE videos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    source_type video_source_type NOT NULL,
    trigger_type video_trigger_type NOT NULL,
    source_event_id varchar(100),
    title varchar(120) NOT NULL,
    description varchar(500),
    storage_key varchar(1024) NOT NULL,
    thumbnail_storage_key varchar(1024),
    content_type varchar(100) NOT NULL DEFAULT 'video/mp4',
    size_bytes bigint,
    checksum_sha256 char(64),
    duration_ms bigint,
    captured_start_at timestamptz,
    captured_end_at timestamptz,
    status video_status NOT NULL DEFAULT 'UPLOADING',
    failure_code varchar(80),
    is_favorite boolean NOT NULL DEFAULT false,
    uploaded_at timestamptz,
    retention_until timestamptz,
    delete_requested_at timestamptz,
    deleted_at timestamptz,
    deleted_by uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_videos_storage_key UNIQUE (storage_key),
    CONSTRAINT uq_videos_id_device UNIQUE (id, device_id),
    CONSTRAINT ck_videos_title CHECK (char_length(btrim(title)) BETWEEN 1 AND 120),
    CONSTRAINT ck_videos_size CHECK (size_bytes IS NULL OR size_bytes BETWEEN 1 AND 524288000),
    CONSTRAINT ck_videos_duration CHECK (duration_ms IS NULL OR duration_ms > 0),
    CONSTRAINT ck_videos_checksum CHECK (checksum_sha256 IS NULL OR checksum_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_videos_capture_range CHECK (
        captured_start_at IS NULL OR captured_end_at IS NULL OR captured_end_at > captured_start_at
    ),
    CONSTRAINT ck_videos_retention CHECK (retention_until IS NULL OR retention_until > created_at),
    CONSTRAINT ck_videos_source_actor CHECK (
        (source_type = 'IOT_CAPTURE' AND created_by IS NULL)
        OR (source_type = 'USER_UPLOAD' AND created_by IS NOT NULL)
    ),
    CONSTRAINT ck_videos_trigger_source CHECK (
        (source_type = 'USER_UPLOAD' AND trigger_type = 'USER_UPLOAD')
        OR (source_type = 'IOT_CAPTURE' AND trigger_type IN ('LAUGHTER', 'WAKE_WORD', 'TOUCH', 'MANUAL'))
    ),
    CONSTRAINT ck_videos_ready_metadata CHECK (
        status <> 'READY'
        OR (size_bytes IS NOT NULL AND checksum_sha256 IS NOT NULL AND duration_ms IS NOT NULL AND uploaded_at IS NOT NULL)
    ),
    CONSTRAINT ck_videos_delete_state CHECK (
        (status = 'DELETED' AND deleted_at IS NOT NULL)
        OR (status <> 'DELETED' AND deleted_at IS NULL)
    )
);

CREATE UNIQUE INDEX ux_videos_device_event
    ON videos (device_id, source_event_id)
    WHERE source_event_id IS NOT NULL;

CREATE INDEX ix_videos_device_feed
    ON videos (device_id, captured_start_at DESC, id DESC)
    WHERE status <> 'DELETED';

CREATE INDEX ix_videos_device_filters
    ON videos (device_id, trigger_type, status, captured_start_at DESC, id DESC)
    WHERE status <> 'DELETED';

CREATE INDEX ix_videos_retention
    ON videos (retention_until)
    WHERE status = 'READY' AND retention_until IS NOT NULL;

CREATE INDEX ix_videos_delete_queue
    ON videos (delete_requested_at)
    WHERE status = 'DELETING';

CREATE TABLE access_logs (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    actor_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    actor_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
    action audit_action NOT NULL,
    target_type varchar(40) NOT NULL,
    target_id uuid,
    outcome audit_outcome NOT NULL,
    reason_code varchar(80),
    ip_address inet,
    user_agent varchar(512),
    request_id varchar(100),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_access_logs_actor CHECK (
        NOT (actor_user_id IS NOT NULL AND actor_device_id IS NOT NULL)
    ),
    CONSTRAINT ck_access_logs_device_actor CHECK (
        actor_device_id IS NULL OR actor_device_id = device_id
    ),
    CONSTRAINT ck_access_logs_target_type CHECK (char_length(btrim(target_type)) BETWEEN 1 AND 40),
    CONSTRAINT ck_access_logs_metadata_object CHECK (jsonb_typeof(metadata) = 'object')
);

CREATE INDEX ix_access_logs_device_time ON access_logs (device_id, created_at DESC, id DESC);
CREATE INDEX ix_access_logs_target ON access_logs (target_type, target_id, created_at DESC);
CREATE INDEX ix_access_logs_actor_user ON access_logs (actor_user_id, created_at DESC) WHERE actor_user_id IS NOT NULL;
CREATE INDEX ix_access_logs_denied ON access_logs (device_id, created_at DESC) WHERE outcome = 'DENIED';

CREATE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_devices_updated_at
BEFORE UPDATE ON devices FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_device_memberships_updated_at
BEFORE UPDATE ON device_memberships FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_invitations_updated_at
BEFORE UPDATE ON invitations FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_videos_updated_at
BEFORE UPDATE ON videos FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON COLUMN users.password_hash IS 'Argon2id or BCrypt hash only; never plaintext.';
COMMENT ON TABLE auth_sessions IS 'Refresh-token sessions. Only SHA-256 token hashes are stored.';
COMMENT ON TABLE registration_codes IS 'Screen-displayed one-time claim codes. 120s TTL, single use, hash only; brute-force is limited per account/IP in the application layer.';
COMMENT ON COLUMN registration_codes.code_hash IS 'SHA-256 hash of the normalized (uppercased, hyphen-stripped) 8-char code. Plaintext exists only on the device screen.';
COMMENT ON TABLE device_memberships IS 'Per-device authorization. A user may join many devices and a device may have many users.';
COMMENT ON COLUMN device_credentials.secret_hash IS 'Hash only. A certificate private key or raw token is never stored here.';
COMMENT ON COLUMN invitations.token_hash IS 'SHA-256 hash of the single-use invitation token.';
COMMENT ON COLUMN videos.storage_key IS 'Private object-storage key; never a public or presigned URL.';
COMMENT ON COLUMN videos.checksum_sha256 IS 'SHA-256 supplied as an object checksum header or metadata and verified with object HEAD after upload.';
COMMENT ON TABLE access_logs IS 'Append-only per-device audit trail. Purge only through the documented retention job.';

COMMIT;
