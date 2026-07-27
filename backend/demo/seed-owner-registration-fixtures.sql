\set ON_ERROR_STOP on

BEGIN;

-- Six resettable demo accounts. Each account starts without device access so
-- the frontend opens device registration. Claiming a code grants OWNER.
DO $$
DECLARE
    fixture_no integer;
    suffix text;
    fixture_email text;
    fixture_password text;
    fixture_code text;
    fixture_device_id uuid;
    fixture_code_id uuid;
    fixture_user_id uuid;
BEGIN
    FOR fixture_no IN 1..6 LOOP
        suffix := lpad(fixture_no::text, 2, '0');
        fixture_email := 'admin' || suffix || '@wj.local';
        fixture_password := 'WjAdmin' || suffix || '!2026';
        fixture_code := 'WJ' || suffix || '2026';
        fixture_device_id :=
            ('20000000-0000-0000-0000-' || lpad(fixture_no::text, 12, '0'))::uuid;
        fixture_code_id :=
            ('23000000-0000-0000-0000-' || lpad(fixture_no::text, 12, '0'))::uuid;

        UPDATE users
           SET password_hash = crypt(fixture_password, gen_salt('bf', 10)),
               display_name = 'Demo Owner ' || suffix,
               status = 'ACTIVE',
               deleted_at = NULL,
               token_version = token_version + 1,
               updated_at = now()
         WHERE lower(email) = fixture_email;

        INSERT INTO users (email, password_hash, display_name)
        SELECT fixture_email,
               crypt(fixture_password, gen_salt('bf', 10)),
               'Demo Owner ' || suffix
         WHERE NOT EXISTS (
             SELECT 1 FROM users WHERE lower(email) = fixture_email
         );

        SELECT id
          INTO fixture_user_id
          FROM users
         WHERE lower(email) = fixture_email;

        -- Reset only these dedicated demo accounts so a new frontend tester
        -- always reaches device registration.
        DELETE FROM device_memberships WHERE user_id = fixture_user_id;
        DELETE FROM invitations WHERE lower(invitee_email) = fixture_email;

        INSERT INTO devices (
            id, serial_number, name, model, firmware_version, status,
            retention_days, registration_mode_expires_at, recording,
            upload_queue_depth
        ) VALUES (
            fixture_device_id,
            'WJ-DEMO-OWNER-' || suffix,
            'Owner Registration Camera ' || suffix,
            'WJ-DEMO-1080P',
            'demo-2.0.0',
            'UNCLAIMED',
            30,
            now() + interval '10 years',
            false,
            0
        )
        ON CONFLICT (id) DO UPDATE SET
            serial_number = EXCLUDED.serial_number,
            name = EXCLUDED.name,
            model = EXCLUDED.model,
            firmware_version = EXCLUDED.firmware_version,
            status = 'UNCLAIMED',
            claimed_at = NULL,
            claimed_by = NULL,
            revoked_at = NULL,
            registration_mode_expires_at = now() + interval '10 years',
            recording = false,
            upload_queue_depth = 0,
            updated_at = now();

        DELETE FROM device_memberships WHERE device_id = fixture_device_id;
        DELETE FROM registration_codes
         WHERE device_id = fixture_device_id
            OR code_hash = encode(digest(fixture_code, 'sha256'), 'hex');

        INSERT INTO registration_codes (id, device_id, code_hash, expires_at)
        VALUES (
            fixture_code_id,
            fixture_device_id,
            encode(digest(fixture_code, 'sha256'), 'hex'),
            now() + interval '10 years'
        );
    END LOOP;
END
$$;

DO $$
DECLARE
    fixture_count integer;
BEGIN
    SELECT count(*)
      INTO fixture_count
      FROM users
     WHERE lower(email) ~ '^admin0[1-6]@wj\.local$'
       AND status = 'ACTIVE'
       AND deleted_at IS NULL;
    IF fixture_count <> 6 THEN
        RAISE EXCEPTION 'Expected 6 active owner registration accounts, found %',
            fixture_count;
    END IF;

    SELECT count(*)
      INTO fixture_count
      FROM registration_codes c
      JOIN devices d ON d.id = c.device_id
     WHERE d.serial_number ~ '^WJ-DEMO-OWNER-0[1-6]$'
       AND d.status = 'UNCLAIMED'
       AND c.used_at IS NULL
       AND c.expires_at > now();
    IF fixture_count <> 6 THEN
        RAISE EXCEPTION 'Expected 6 unused owner registration codes, found %',
            fixture_count;
    END IF;
END
$$;

COMMIT;
