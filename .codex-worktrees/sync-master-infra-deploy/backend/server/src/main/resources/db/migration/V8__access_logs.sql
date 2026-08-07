DO $$
BEGIN
    CREATE TYPE audit_outcome AS ENUM ('SUCCESS', 'DENIED', 'FAILED');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE audit_action AS ENUM (
        'MEMBER_INVITE', 'MEMBER_REVOKE', 'DEVICE_CLAIM', 'DEVICE_UPDATE', 'DEVICE_REVOKE',
        'VIDEO_LIST', 'VIDEO_VIEW', 'VIDEO_PLAY', 'VIDEO_DOWNLOAD', 'VIDEO_EDIT', 'VIDEO_DELETE',
        'STREAM_OPEN', 'STREAM_HEARTBEAT', 'STREAM_CLOSE'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS access_logs (
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

CREATE INDEX IF NOT EXISTS ix_access_logs_device_time
    ON access_logs (device_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS ix_access_logs_target
    ON access_logs (target_type, target_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_access_logs_actor_user
    ON access_logs (actor_user_id, created_at DESC) WHERE actor_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_access_logs_denied
    ON access_logs (device_id, created_at DESC) WHERE outcome = 'DENIED';
