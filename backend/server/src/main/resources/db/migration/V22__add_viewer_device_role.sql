-- PostgreSQL requires a commit before a newly-added enum value can be used.
ALTER TYPE device_role ADD VALUE IF NOT EXISTS 'VIEWER';

