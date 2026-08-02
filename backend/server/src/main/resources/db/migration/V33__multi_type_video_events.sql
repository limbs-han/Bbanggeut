ALTER TYPE video_trigger_type ADD VALUE IF NOT EXISTS 'CLAP';

ALTER TABLE videos
    ADD COLUMN IF NOT EXISTS event_types video_trigger_type[];

UPDATE videos
   SET event_types = ARRAY[trigger_type]
 WHERE event_types IS NULL OR cardinality(event_types) = 0;

ALTER TABLE videos
    ALTER COLUMN event_types SET NOT NULL;

ALTER TABLE videos
    DROP CONSTRAINT IF EXISTS ck_videos_event_types;

ALTER TABLE videos
    ADD CONSTRAINT ck_videos_event_types CHECK (
        cardinality(event_types) BETWEEN 1 AND 3
        AND trigger_type = ANY(event_types)
    );

ALTER TABLE device_events
    DROP CONSTRAINT IF EXISTS ck_device_events_type;

ALTER TABLE device_events
    ADD CONSTRAINT ck_device_events_type CHECK (
        event_type IN ('LAUGHTER', 'CLAP', 'WAKE_WORD', 'TOUCH', 'MANUAL')
    );
