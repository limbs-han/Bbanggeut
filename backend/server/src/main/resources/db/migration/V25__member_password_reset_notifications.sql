ALTER TABLE device_memberships ALTER COLUMN role DROP DEFAULT;
ALTER TABLE invitations ALTER COLUMN role DROP DEFAULT;

ALTER TABLE invitations DROP CONSTRAINT IF EXISTS ck_invitations_non_owner_only;

UPDATE device_memberships SET role = 'MEMBER' WHERE role::text IN ('EDITOR', 'VIEWER');
UPDATE invitations SET role = 'MEMBER' WHERE role::text IN ('EDITOR', 'VIEWER');

ALTER TABLE device_memberships ALTER COLUMN role SET DEFAULT 'MEMBER';
ALTER TABLE invitations ALTER COLUMN role SET DEFAULT 'MEMBER';

ALTER TABLE device_memberships
    ADD CONSTRAINT ck_device_memberships_owner_or_member
    CHECK (role IN ('OWNER', 'MEMBER'));
ALTER TABLE invitations
    ADD CONSTRAINT ck_invitations_member_only CHECK (role = 'MEMBER');

CREATE TABLE password_reset_tokens (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash char(64) NOT NULL,
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_password_reset_tokens_hash CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_password_reset_tokens_expiry CHECK (expires_at > created_at)
);

CREATE UNIQUE INDEX ux_password_reset_tokens_hash
    ON password_reset_tokens (token_hash);
CREATE INDEX ix_password_reset_tokens_user_active
    ON password_reset_tokens (user_id, expires_at DESC)
    WHERE used_at IS NULL;

CREATE TYPE notification_type AS ENUM ('INVITATION_RECEIVED', 'LAUGHTER_VIDEO_READY');

CREATE TABLE notifications (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type notification_type NOT NULL,
    title varchar(120) NOT NULL,
    body varchar(500) NOT NULL,
    device_id uuid REFERENCES devices(id) ON DELETE CASCADE,
    resource_id uuid,
    dedupe_key varchar(200) NOT NULL,
    read_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX ux_notifications_user_dedupe
    ON notifications (user_id, dedupe_key);
CREATE INDEX ix_notifications_user_created
    ON notifications (user_id, created_at DESC, id DESC);
CREATE INDEX ix_notifications_user_unread
    ON notifications (user_id, created_at DESC)
    WHERE read_at IS NULL;
