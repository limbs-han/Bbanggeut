DO $$
BEGIN
    CREATE TYPE video_edit_status AS ENUM ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED', 'CANCELLED');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS video_edits (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE RESTRICT,
    source_video_id uuid NOT NULL,
    result_video_id uuid UNIQUE,
    requested_by uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    start_ms bigint NOT NULL CHECK (start_ms >= 0),
    end_ms bigint NOT NULL CHECK (end_ms > 0),
    title varchar(120) NOT NULL,
    status video_edit_status NOT NULL DEFAULT 'PENDING',
    error_code varchar(80),
    requested_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT fk_video_edits_source_device FOREIGN KEY (source_video_id, device_id)
        REFERENCES videos(id, device_id) ON DELETE RESTRICT,
    CONSTRAINT fk_video_edits_result_device FOREIGN KEY (result_video_id, device_id)
        REFERENCES videos(id, device_id) ON DELETE RESTRICT,
    CONSTRAINT ck_video_edits_range CHECK (end_ms > start_ms),
    CONSTRAINT ck_video_edits_result CHECK (
        (status = 'COMPLETED' AND result_video_id IS NOT NULL AND completed_at IS NOT NULL AND error_code IS NULL)
        OR (status = 'FAILED' AND result_video_id IS NULL AND completed_at IS NOT NULL AND error_code IS NOT NULL)
        OR (status = 'CANCELLED' AND result_video_id IS NULL AND completed_at IS NOT NULL)
        OR (status IN ('PENDING', 'PROCESSING') AND result_video_id IS NULL AND completed_at IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS ix_video_edits_source ON video_edits (source_video_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS ix_video_edits_device ON video_edits (device_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS ix_video_edits_worker_queue
    ON video_edits (status, requested_at) WHERE status IN ('PENDING', 'PROCESSING');
CREATE INDEX IF NOT EXISTS ix_video_edits_requester ON video_edits (requested_by, requested_at DESC);
