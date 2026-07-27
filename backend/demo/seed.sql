\set ON_ERROR_STOP on

BEGIN;
SET CONSTRAINTS ALL DEFERRED;

-- Fixed demo accounts. Passwords are supplied by start-demo.ps1 and hashed in PostgreSQL.
UPDATE users
   SET password_hash = crypt(:'admin_password', gen_salt('bf', 10)),
       display_name = 'Demo Admin', status = 'ACTIVE', deleted_at = NULL,
       token_version = token_version + 1, updated_at = now()
 WHERE email = 'admin@wj.local';
INSERT INTO users (email, password_hash, display_name)
SELECT 'admin@wj.local', crypt(:'admin_password', gen_salt('bf', 10)), 'Demo Admin'
 WHERE NOT EXISTS (SELECT 1 FROM users WHERE email = 'admin@wj.local');

UPDATE users
   SET password_hash = crypt(:'family_password', gen_salt('bf', 10)),
       display_name = 'Demo Family', status = 'ACTIVE', deleted_at = NULL, updated_at = now()
 WHERE email = 'family@wj.local';
INSERT INTO users (email, password_hash, display_name)
SELECT 'family@wj.local', crypt(:'family_password', gen_salt('bf', 10)), 'Demo Family'
 WHERE NOT EXISTS (SELECT 1 FROM users WHERE email = 'family@wj.local');

UPDATE users
   SET password_hash = crypt(:'request_password', gen_salt('bf', 10)),
       display_name = 'Pending Family', status = 'ACTIVE', deleted_at = NULL, updated_at = now()
 WHERE email = 'request@wj.local';
INSERT INTO users (email, password_hash, display_name)
SELECT 'request@wj.local', crypt(:'request_password', gen_salt('bf', 10)), 'Pending Family'
 WHERE NOT EXISTS (SELECT 1 FROM users WHERE email = 'request@wj.local');

-- Claimed online camera used by every authenticated frontend screen.
INSERT INTO devices (
    id, serial_number, name, model, firmware_version, status, retention_days,
    claimed_at, claimed_by, last_seen_at, recording, upload_queue_depth,
    buffer_seconds, person_count, subscription_active
) VALUES (
    '10000000-0000-0000-0000-000000000001', 'WJ-DEMO-LIVE-001',
    'Living Room HomeCam', 'WJ-DEMO-1080P', 'demo-1.0.0', 'ONLINE', 30,
    now() - interval '30 days', (SELECT id FROM users WHERE email = 'admin@wj.local'),
    now(), true, 0, 30, 2, false
)
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name, model = EXCLUDED.model, firmware_version = EXCLUDED.firmware_version,
    status = 'ONLINE', retention_days = 30, claimed_at = EXCLUDED.claimed_at,
    claimed_by = EXCLUDED.claimed_by, revoked_at = NULL, last_seen_at = now(),
    recording = true, upload_queue_depth = 0, buffer_seconds = 30, person_count = 2,
    subscription_active = false, subscription_grace_until = NULL, updated_at = now();

INSERT INTO device_memberships (id, device_id, user_id, role, status)
VALUES (
    '11000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    (SELECT id FROM users WHERE email = 'admin@wj.local'), 'OWNER', 'ACTIVE'
)
ON CONFLICT (device_id, user_id) DO UPDATE SET
    role = 'OWNER', status = 'ACTIVE', revoked_at = NULL, revoked_by = NULL, updated_at = now();

INSERT INTO device_memberships (id, device_id, user_id, role, status)
VALUES (
    '11000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000001',
    (SELECT id FROM users WHERE email = 'family@wj.local'), 'EDITOR', 'ACTIVE'
)
ON CONFLICT (device_id, user_id) DO UPDATE SET
    role = 'EDITOR', status = 'ACTIVE', revoked_at = NULL, revoked_by = NULL, updated_at = now();

-- A pending invitation makes the invitee accept/decline UI testable.
DELETE FROM invitations
 WHERE device_id = '10000000-0000-0000-0000-000000000001'
   AND lower(invitee_email) = 'request@wj.local';
INSERT INTO invitations (id, device_id, inviter_id, invitee_email, role, status, expires_at, created_at)
VALUES (
    '12000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    (SELECT id FROM users WHERE email = 'admin@wj.local'),
    'request@wj.local', 'VIEWER', 'PENDING', now() + interval '7 days', now() - interval '10 minutes'
);

-- Separate unclaimed camera for testing the fixed registration code WJDE-2026.
INSERT INTO devices (
    id, serial_number, name, model, firmware_version, status, retention_days,
    registration_mode_expires_at, recording, upload_queue_depth
) VALUES (
    '10000000-0000-0000-0000-000000000002', 'WJ-DEMO-CLAIM-002',
    'Registration Test Camera', 'WJ-DEMO-1080P', 'demo-1.0.0', 'UNCLAIMED', 30,
    now() + interval '10 years', false, 0
)
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name, model = EXCLUDED.model, firmware_version = EXCLUDED.firmware_version,
    status = 'UNCLAIMED', claimed_at = NULL, claimed_by = NULL, revoked_at = NULL,
    registration_mode_expires_at = now() + interval '10 years', recording = false,
    upload_queue_depth = 0, updated_at = now();
DELETE FROM device_memberships WHERE device_id = '10000000-0000-0000-0000-000000000002';
DELETE FROM registration_codes
 WHERE device_id = '10000000-0000-0000-0000-000000000002'
    OR code_hash = encode(digest('WJDE2026', 'sha256'), 'hex');
INSERT INTO registration_codes (id, device_id, code_hash, expires_at)
VALUES (
    '13000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000002',
    encode(digest('WJDE2026', 'sha256'), 'hex'), now() + interval '10 years'
);

-- Three overlapping two-minute clips exercise lists, filters, favorites, memo and playback/download.
DELETE FROM video_deletion_jobs
 WHERE video_id IN (
    '14000000-0000-0000-0000-000000000001',
    '14000000-0000-0000-0000-000000000002',
    '14000000-0000-0000-0000-000000000003'
 );
INSERT INTO videos (
    id, device_id, source_type, trigger_type, source_event_id, title, description,
    storage_key, content_type, size_bytes, checksum_sha256, duration_ms,
    captured_start_at, captured_end_at, status, is_favorite, uploaded_at,
    retention_until, created_at, updated_at
) VALUES
(
    '14000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001',
    'IOT_CAPTURE', 'LAUGHTER', 'demo-clip-01', 'Morning family moment',
    'A seeded two-minute clip with a memo.', 'private/10000000-0000-0000-0000-000000000001/events/demo-clip-01.mp4',
    'video/mp4', :clip1_size, :'clip1_sha', :clip1_duration,
    now() - interval '2 days', now() - interval '2 days' + (:clip1_duration * interval '1 millisecond'),
    'READY', true, now() - interval '2 days', now() + interval '30 days', now() - interval '2 days', now()
),
(
    '14000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001',
    'IOT_CAPTURE', 'WAKE_WORD', 'demo-clip-02', 'Afternoon check-in', NULL,
    'private/10000000-0000-0000-0000-000000000001/events/demo-clip-02.mp4',
    'video/mp4', :clip2_size, :'clip2_sha', :clip2_duration,
    now() - interval '1 day', now() - interval '1 day' + (:clip2_duration * interval '1 millisecond'),
    'READY', false, now() - interval '1 day', now() + interval '30 days', now() - interval '1 day', now()
),
(
    '14000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001',
    'IOT_CAPTURE', 'TOUCH', 'demo-clip-03', 'Evening highlight',
    'Use this clip to test editing, favorite and deletion UI.',
    'private/10000000-0000-0000-0000-000000000001/events/demo-clip-03.mp4',
    'video/mp4', :clip3_size, :'clip3_sha', :clip3_duration,
    now() - interval '3 hours', now() - interval '3 hours' + (:clip3_duration * interval '1 millisecond'),
    'READY', false, now() - interval '3 hours', now() + interval '30 days', now() - interval '3 hours', now()
)
ON CONFLICT (id) DO UPDATE SET
    trigger_type = EXCLUDED.trigger_type, title = EXCLUDED.title, description = EXCLUDED.description,
    storage_key = EXCLUDED.storage_key, size_bytes = EXCLUDED.size_bytes,
    checksum_sha256 = EXCLUDED.checksum_sha256, duration_ms = EXCLUDED.duration_ms,
    captured_start_at = EXCLUDED.captured_start_at, captured_end_at = EXCLUDED.captured_end_at,
    status = 'READY', is_favorite = EXCLUDED.is_favorite, uploaded_at = EXCLUDED.uploaded_at,
    retention_until = EXCLUDED.retention_until, deleted_at = NULL, deleted_by = NULL,
    delete_requested_at = NULL, updated_at = now();

DELETE FROM access_logs WHERE metadata @> '{"demo": true}'::jsonb;
INSERT INTO access_logs (
    device_id, actor_user_id, action, target_type, target_id, outcome, metadata, created_at
) VALUES
('10000000-0000-0000-0000-000000000001', (SELECT id FROM users WHERE email='admin@wj.local'),
 'VIDEO_VIEW', 'VIDEO', '14000000-0000-0000-0000-000000000001', 'SUCCESS', '{"demo":true}', now() - interval '2 hours'),
('10000000-0000-0000-0000-000000000001', (SELECT id FROM users WHERE email='family@wj.local'),
 'VIDEO_PLAY', 'VIDEO', '14000000-0000-0000-0000-000000000002', 'SUCCESS', '{"demo":true}', now() - interval '1 hour'),
('10000000-0000-0000-0000-000000000001', (SELECT id FROM users WHERE email='admin@wj.local'),
 'STREAM_OPEN', 'STREAM_SESSION', NULL, 'SUCCESS', '{"demo":true}', now() - interval '20 minutes');

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM device_memberships m
          JOIN users u ON u.id = m.user_id
         WHERE u.email = 'admin@wj.local'
           AND m.device_id = '10000000-0000-0000-0000-000000000001'
           AND m.role = 'OWNER' AND m.status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Demo OWNER fixture was not created';
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM device_memberships m
          JOIN users u ON u.id = m.user_id
         WHERE u.email = 'family@wj.local'
           AND m.device_id = '10000000-0000-0000-0000-000000000001'
           AND m.role = 'EDITOR' AND m.status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Demo EDITOR fixture was not created';
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM invitations i
         WHERE i.invitee_email = 'request@wj.local'
           AND i.device_id = '10000000-0000-0000-0000-000000000001'
           AND i.role = 'VIEWER' AND i.status = 'PENDING'
    ) THEN
        RAISE EXCEPTION 'Demo pending invitation fixture was not created';
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM registration_codes c
         WHERE c.device_id = '10000000-0000-0000-0000-000000000002'
           AND c.code_hash = encode(digest('WJDE2026', 'sha256'), 'hex')
           AND c.used_at IS NULL AND c.expires_at > now()
    ) THEN
        RAISE EXCEPTION 'Demo registration code fixture was not created';
    END IF;
END
$$;

COMMIT;
