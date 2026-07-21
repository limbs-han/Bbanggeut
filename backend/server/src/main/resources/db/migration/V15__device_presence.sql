-- Home-cam refit: the edge reports how many people it currently detects in
-- frame via heartbeat. Presence is transient telemetry, so it lives on the
-- device row next to recording/buffer status and is nullable (unknown until
-- the device reports, or when presence detection is off).
ALTER TABLE devices ADD COLUMN IF NOT EXISTS person_count integer;

ALTER TABLE devices DROP CONSTRAINT IF EXISTS ck_devices_person_count;
ALTER TABLE devices ADD CONSTRAINT ck_devices_person_count
    CHECK (person_count IS NULL OR person_count >= 0);
