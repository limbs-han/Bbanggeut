-- The nightly retention job deletes by age alone:
--   DELETE FROM auth_login_attempts WHERE attempted_at < ?
--
-- Every existing index on these tables leads with the bucket column and is
-- partial on succeeded = false, so neither can serve that predicate and the
-- job falls back to a sequential scan of the whole retention period.
--
-- Rate limiting itself no longer reads these tables, so the bucket indexes are
-- left in place only for incident lookups.

CREATE INDEX IF NOT EXISTS ix_auth_login_attempt_retention
    ON auth_login_attempts (attempted_at);

CREATE INDEX IF NOT EXISTS ix_device_claim_attempt_retention
    ON device_claim_attempts (attempted_at);
