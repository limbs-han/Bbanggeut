-- Split the former MEMBER role into explicit editing and viewing roles.
-- Renaming preserves the permissions of every existing MEMBER.
ALTER TYPE device_role RENAME VALUE 'MEMBER' TO 'EDITOR';
