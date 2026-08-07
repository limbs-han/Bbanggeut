DO $$
BEGIN
    CREATE TYPE device_stream_status AS ENUM ('STARTING', 'RUNNING', 'STOP_PENDING', 'STOPPING', 'STOPPED', 'FAILED');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE stream_session_status AS ENUM ('PENDING', 'READY', 'FAILED', 'CLOSED', 'EXPIRED');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS device_streams (
    id uuid PRIMARY KEY,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    status device_stream_status NOT NULL DEFAULT 'STARTING',
    edge_hard_expires_at timestamptz NOT NULL,
    stop_deadline_at timestamptz,
    failure_code varchar(80),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_device_streams_id_device UNIQUE (id, device_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_device_streams_one_live
    ON device_streams (device_id) WHERE status IN ('STARTING', 'RUNNING', 'STOP_PENDING');
CREATE INDEX IF NOT EXISTS ix_device_streams_stop
    ON device_streams (stop_deadline_at) WHERE status = 'STOP_PENDING';

CREATE TABLE IF NOT EXISTS stream_sessions (
    id uuid PRIMARY KEY,
    stream_id uuid NOT NULL,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    status stream_session_status NOT NULL DEFAULT 'PENDING',
    last_activity_at timestamptz NOT NULL,
    viewer_expires_at timestamptz NOT NULL,
    failure_code varchar(80),
    closed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_stream_session_stream_device FOREIGN KEY (stream_id, device_id)
        REFERENCES device_streams(id, device_id) ON DELETE RESTRICT,
    CONSTRAINT ck_stream_session_terminal CHECK (
        (status IN ('CLOSED', 'EXPIRED') AND closed_at IS NOT NULL)
        OR (status = 'FAILED' AND failure_code IS NOT NULL)
        OR (status IN ('PENDING', 'READY') AND closed_at IS NULL AND failure_code IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS ix_stream_sessions_owner ON stream_sessions (user_id, id);
CREATE INDEX IF NOT EXISTS ix_stream_sessions_active
    ON stream_sessions (device_id, viewer_expires_at) WHERE status IN ('PENDING', 'READY');
