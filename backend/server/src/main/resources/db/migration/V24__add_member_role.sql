-- PostgreSQL requires the transaction that adds an enum value to commit before
-- the value can be used. The data conversion therefore lives in V25.
ALTER TYPE device_role ADD VALUE IF NOT EXISTS 'MEMBER';
