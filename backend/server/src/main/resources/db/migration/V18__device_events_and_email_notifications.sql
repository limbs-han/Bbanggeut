-- Raw edge events are not the same thing as uploaded videos. Keeping them
-- separately preserves detections whose clip generation or upload later fails.
CREATE TABLE IF NOT EXISTS device_events (
    id uuid PRIMARY KEY,
    device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    event_type varchar(20) NOT NULL,
    occurred_at timestamptz NOT NULL,
    confidence numeric(6,5),
    local_clip_state varchar(20),
    before_ms integer,
    after_ms integer,
    merge_window_ms integer,
    source_node_id varchar(80),
    source_component varchar(40),
    source_model_version varchar(80),
    video_id uuid REFERENCES videos(id) ON DELETE SET NULL,
    upload_status varchar(20) NOT NULL DEFAULT 'DETECTED',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_device_events_type
        CHECK (event_type IN ('LAUGHTER', 'WAKE_WORD', 'TOUCH', 'MANUAL')),
    CONSTRAINT ck_device_events_confidence
        CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    CONSTRAINT ck_device_events_clip_state
        CHECK (local_clip_state IS NULL OR local_clip_state IN
            ('SEGMENTS_LOCKED', 'GENERATING', 'QUEUED', 'FAILED')),
    CONSTRAINT ck_device_events_durations CHECK (
        (before_ms IS NULL OR before_ms BETWEEN 0 AND 3600000)
        AND (after_ms IS NULL OR after_ms BETWEEN 0 AND 3600000)
        AND (merge_window_ms IS NULL OR merge_window_ms BETWEEN 0 AND 600000)
    ),
    CONSTRAINT ck_device_events_upload_status
        CHECK (upload_status IN ('DETECTED', 'UPLOADING', 'READY', 'FAILED'))
);

CREATE INDEX IF NOT EXISTS ix_device_events_device_occurred
    ON device_events (device_id, occurred_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS ix_device_events_device_type_occurred
    ON device_events (device_id, event_type, occurred_at DESC);

CREATE TABLE IF NOT EXISTS event_email_notifications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id uuid NOT NULL REFERENCES device_events(id) ON DELETE CASCADE,
    recipient_email varchar(320) NOT NULL,
    status varchar(20) NOT NULL DEFAULT 'PENDING',
    attempts integer NOT NULL DEFAULT 0,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    last_error_code varchar(120),
    sent_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_event_email_recipient UNIQUE (event_id, recipient_email),
    CONSTRAINT ck_event_email_status CHECK (status IN ('PENDING', 'SENT', 'FAILED')),
    CONSTRAINT ck_event_email_attempts CHECK (attempts >= 0)
);

CREATE INDEX IF NOT EXISTS ix_event_email_due
    ON event_email_notifications (next_attempt_at, created_at)
    WHERE status = 'PENDING';
