DO $$
BEGIN
    CREATE TYPE video_source_type AS ENUM ('IOT_CAPTURE', 'USER_UPLOAD', 'EDIT_OUTPUT');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE video_trigger_type AS ENUM ('LAUGHTER', 'WAKE_WORD', 'TOUCH', 'MANUAL', 'USER_UPLOAD', 'EDIT');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
    CREATE TYPE video_status AS ENUM ('UPLOADING', 'PROCESSING', 'READY', 'FAILED', 'DELETING', 'DELETED');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$$;

CREATE TABLE IF NOT EXISTS videos (
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
    CONSTRAINT ck_videos_size CHECK (size_bytes IS NULL OR size_bytes BETWEEN 1 AND 524288000),
    CONSTRAINT ck_videos_duration CHECK (duration_ms IS NULL OR duration_ms > 0),
    CONSTRAINT ck_videos_checksum CHECK (checksum_sha256 IS NULL OR checksum_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_videos_capture_range CHECK (
        captured_start_at IS NULL OR captured_end_at IS NULL OR captured_end_at > captured_start_at
    )
);

-- Compatibility for the initial skeleton video table.
ALTER TABLE videos ADD COLUMN IF NOT EXISTS title varchar(120);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS description varchar(500);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS thumbnail_storage_key varchar(1024);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS content_type varchar(100) NOT NULL DEFAULT 'video/mp4';
ALTER TABLE videos ADD COLUMN IF NOT EXISTS duration_ms bigint;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS captured_end_at timestamptz;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS failure_code varchar(80);
ALTER TABLE videos ADD COLUMN IF NOT EXISTS is_favorite boolean NOT NULL DEFAULT false;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS uploaded_at timestamptz;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS retention_until timestamptz;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS delete_requested_at timestamptz;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS deleted_by uuid REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE videos ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
UPDATE videos SET title = 'Untitled video' WHERE title IS NULL;
UPDATE videos SET trigger_type = 'TOUCH' WHERE trigger_type IS NULL;
ALTER TABLE videos ALTER COLUMN title SET NOT NULL;
ALTER TABLE videos ALTER COLUMN storage_key TYPE varchar(1024);
ALTER TABLE videos ALTER COLUMN source_event_id TYPE varchar(100);
ALTER TABLE videos DROP CONSTRAINT IF EXISTS videos_source_type_check;
ALTER TABLE videos DROP CONSTRAINT IF EXISTS videos_trigger_type_check;
ALTER TABLE videos DROP CONSTRAINT IF EXISTS videos_status_check;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema='public' AND table_name='videos'
           AND column_name='source_type' AND udt_name <> 'video_source_type'
    ) THEN
        ALTER TABLE videos ALTER COLUMN source_type DROP DEFAULT;
        ALTER TABLE videos ALTER COLUMN source_type TYPE video_source_type
            USING (CASE source_type::text
                WHEN 'DEVICE_EVENT' THEN 'IOT_CAPTURE'
                WHEN 'EDIT_RESULT' THEN 'EDIT_OUTPUT'
                ELSE source_type::text
            END)::video_source_type;
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema='public' AND table_name='videos'
           AND column_name='trigger_type' AND udt_name <> 'video_trigger_type'
    ) THEN
        ALTER TABLE videos ALTER COLUMN trigger_type TYPE video_trigger_type
            USING (CASE trigger_type::text
                WHEN 'LAUGH' THEN 'LAUGHTER'
                WHEN 'WAKEWORD' THEN 'WAKE_WORD'
                ELSE trigger_type::text
            END)::video_trigger_type;
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema='public' AND table_name='videos'
           AND column_name='status' AND udt_name <> 'video_status'
    ) THEN
        ALTER TABLE videos ALTER COLUMN status DROP DEFAULT;
        ALTER TABLE videos ALTER COLUMN status TYPE video_status USING status::text::video_status;
        ALTER TABLE videos ALTER COLUMN status SET DEFAULT 'UPLOADING';
    END IF;
END
$$;

ALTER TABLE videos ALTER COLUMN source_type SET DEFAULT 'IOT_CAPTURE';
ALTER TABLE videos ALTER COLUMN trigger_type SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_videos_storage_key ON videos (storage_key);
CREATE UNIQUE INDEX IF NOT EXISTS ux_videos_device_event
    ON videos (device_id, source_event_id) WHERE source_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_videos_device_feed
    ON videos (device_id, captured_start_at DESC, id DESC) WHERE status <> 'DELETED';
