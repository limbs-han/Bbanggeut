DO $$
BEGIN
    CREATE TYPE deletion_job_status AS ENUM ('PENDING', 'PROCESSING', 'RETRY', 'COMPLETED');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS video_deletion_jobs (
    id bigserial PRIMARY KEY,
    video_id uuid NOT NULL UNIQUE REFERENCES videos(id) ON DELETE RESTRICT,
    status deletion_job_status NOT NULL DEFAULT 'PENDING',
    attempts integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    locked_at timestamptz,
    last_error_code varchar(80),
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz
);

CREATE INDEX IF NOT EXISTS ix_video_deletion_jobs_ready
    ON video_deletion_jobs (next_attempt_at, id)
    WHERE status IN ('PENDING', 'RETRY', 'PROCESSING');
