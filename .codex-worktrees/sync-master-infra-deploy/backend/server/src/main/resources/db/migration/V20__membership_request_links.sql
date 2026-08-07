CREATE TABLE IF NOT EXISTS membership_request_links (
    id uuid PRIMARY KEY,
    requester_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash char(64) NOT NULL,
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    used_by uuid REFERENCES users(id) ON DELETE SET NULL,
    invitation_id uuid REFERENCES invitations(id) ON DELETE SET NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_membership_request_token UNIQUE (token_hash),
    CONSTRAINT ck_membership_request_token_hash CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_membership_request_expiry CHECK (expires_at > created_at),
    CONSTRAINT ck_membership_request_use CHECK (
        (used_at IS NULL AND used_by IS NULL AND invitation_id IS NULL)
        OR (used_at IS NOT NULL AND used_by IS NOT NULL AND invitation_id IS NOT NULL)
    ),
    CONSTRAINT ck_membership_request_revocation CHECK (
        revoked_at IS NULL OR used_at IS NULL
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_membership_request_one_active
    ON membership_request_links (requester_id)
    WHERE used_at IS NULL AND revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS ix_membership_request_expiry
    ON membership_request_links (expires_at)
    WHERE used_at IS NULL AND revoked_at IS NULL;
