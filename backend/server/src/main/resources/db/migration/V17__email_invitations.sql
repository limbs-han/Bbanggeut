-- Replace the shareable invite link + join-request flow with direct email
-- invitations that the invited account accepts in-app. A home camera should be
-- shared with specific known people, never through a link that can leak, so the
-- owner invites an email and only that account can accept.

-- 1) Drop the link/join-request model from V12 (device subscription columns and
--    the retention index from V12 stay).
DROP TABLE IF EXISTS join_requests;
DROP TABLE IF EXISTS device_invite_links;
DROP TYPE IF EXISTS join_request_status;

-- 2) Direct, email-bound invitations with an in-app accept/decline step.
DO $$
BEGIN
    CREATE TYPE invitation_status AS ENUM ('PENDING', 'ACCEPTED', 'DECLINED', 'EXPIRED', 'REVOKED');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS invitations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    inviter_id uuid REFERENCES users(id) ON DELETE SET NULL,
    invitee_email varchar(320) NOT NULL,
    role device_role NOT NULL DEFAULT 'MEMBER',
    status invitation_status NOT NULL DEFAULT 'PENDING',
    expires_at timestamptz NOT NULL,
    decided_by uuid REFERENCES users(id) ON DELETE SET NULL,
    decided_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_invitations_email_normalized CHECK (invitee_email = lower(btrim(invitee_email))),
    CONSTRAINT ck_invitations_email_shape CHECK (position('@' in invitee_email) > 1),
    CONSTRAINT ck_invitations_member_only CHECK (role = 'MEMBER'),
    CONSTRAINT ck_invitations_expiry CHECK (expires_at > created_at),
    CONSTRAINT ck_invitations_decision CHECK (
        (status = 'PENDING' AND decided_at IS NULL)
        OR (status <> 'PENDING' AND decided_at IS NOT NULL)
    )
);

-- At most one live invitation per (device, email); the invitee list and the
-- owner's outstanding-invite list are both index-backed.
CREATE UNIQUE INDEX IF NOT EXISTS ux_invitations_one_pending_per_email
    ON invitations (device_id, lower(invitee_email)) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS ix_invitations_device_status
    ON invitations (device_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_invitations_email_status
    ON invitations (lower(invitee_email), status, expires_at);
