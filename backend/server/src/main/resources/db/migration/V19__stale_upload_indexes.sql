CREATE INDEX IF NOT EXISTS ix_videos_stale_upload
    ON videos (updated_at, id)
    WHERE status = 'UPLOADING';

CREATE INDEX IF NOT EXISTS ix_device_events_video
    ON device_events (video_id)
    WHERE video_id IS NOT NULL;
