-- Server-side edit rendering was retired. Editing/export now happens on the client
-- after obtaining the original video's short-lived download URL.
-- Keep the legacy table for deployed database compatibility and audit history, but
-- make sure work queued by an older application version is never picked up later.
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'VIDEO_UPDATE';

UPDATE video_edits
   SET status = 'CANCELLED',
       completed_at = now(),
       updated_at = now(),
       error_code = NULL
 WHERE status IN ('PENDING', 'PROCESSING');
