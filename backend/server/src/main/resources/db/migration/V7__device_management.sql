ALTER TABLE devices ADD COLUMN IF NOT EXISTS recording boolean NOT NULL DEFAULT false;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS upload_queue_depth integer NOT NULL DEFAULT 0;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS buffer_seconds integer;

ALTER TABLE devices DROP CONSTRAINT IF EXISTS ck_devices_upload_queue_depth;
ALTER TABLE devices ADD CONSTRAINT ck_devices_upload_queue_depth CHECK (upload_queue_depth >= 0);
ALTER TABLE devices DROP CONSTRAINT IF EXISTS ck_devices_buffer_seconds;
ALTER TABLE devices ADD CONSTRAINT ck_devices_buffer_seconds CHECK (buffer_seconds IS NULL OR buffer_seconds >= 0);
