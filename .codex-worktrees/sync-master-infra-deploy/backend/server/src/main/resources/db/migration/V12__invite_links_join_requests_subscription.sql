-- Invitation revamp (shareable invite link + owner approval), device subscription
-- (extended retention while active, 30-day grace after cancel) and retention
-- expiry housekeeping.

-- 1) Email-bound invitations are replaced by per-device invite links.
DROP TABLE IF EXISTS invitations;

CREATE TABLE IF NOT EXISTS device_invite_links (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    token_hash char(64) NOT NULL,
    created_by uuid REFERENCES users(id) ON DELETE SET NULL,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_device_invite_links_token UNIQUE (token_hash),
    CONSTRAINT ck_device_invite_links_token CHECK (token_hash ~ '^[0-9a-f]{64}$')
);

-- Rotating the link revokes the previous one; only one live link per device.
CREATE UNIQUE INDEX IF NOT EXISTS ux_device_invite_links_active
    ON device_invite_links (device_id)
    WHERE revoked_at IS NULL;

-- 2) Clicking a valid link creates a join request; the OWNER approves or rejects.
DO $$
BEGIN
    CREATE TYPE join_request_status AS ENUM ('PENDING', 'APPROVED', 'REJECTED', 'CANCELLED');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS join_requests (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status join_request_status NOT NULL DEFAULT 'PENDING',
    requested_at timestamptz NOT NULL DEFAULT now(),
    decided_at timestamptz,
    decided_by uuid REFERENCES users(id) ON DELETE SET NULL,
    CONSTRAINT ck_join_requests_decision CHECK (
        (status = 'PENDING' AND decided_at IS NULL)
        OR (status <> 'PENDING' AND decided_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_join_requests_pending
    ON join_requests (device_id, user_id)
    WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS ix_join_requests_device_pending
    ON join_requests (device_id, requested_at)
    WHERE status = 'PENDING';

-- 3) Device subscription: active subscription extends video retention; after
--    cancel a grace window keeps over-baseline videos readable before deletion.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS subscription_active boolean NOT NULL DEFAULT false;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS subscription_grace_until timestamptz;

-- 4) Retention housekeeping: backfill missing retention_until for live videos
--    and index the expiry sweep.
UPDATE videos v
   SET retention_until = COALESCE(v.uploaded_at, v.created_at) + make_interval(days => d.retention_days)
  FROM devices d
 WHERE d.id = v.device_id
   AND v.retention_until IS NULL
   AND v.status NOT IN ('DELETING', 'DELETED');

CREATE INDEX IF NOT EXISTS ix_videos_retention_due
    ON videos (retention_until)
    WHERE status IN ('READY', 'FAILED') AND retention_until IS NOT NULL;
