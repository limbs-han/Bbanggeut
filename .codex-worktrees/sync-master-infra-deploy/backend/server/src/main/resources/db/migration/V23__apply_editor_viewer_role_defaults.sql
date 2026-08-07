ALTER TABLE device_memberships ALTER COLUMN role SET DEFAULT 'VIEWER';
ALTER TABLE invitations ALTER COLUMN role SET DEFAULT 'VIEWER';

ALTER TABLE invitations
    DROP CONSTRAINT IF EXISTS ck_invitations_member_only;
ALTER TABLE invitations
    ADD CONSTRAINT ck_invitations_non_owner_only
    CHECK (role IN ('EDITOR', 'VIEWER'));
