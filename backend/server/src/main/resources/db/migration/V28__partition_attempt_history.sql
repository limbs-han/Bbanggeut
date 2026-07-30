-- Attempt history is time series data with a fixed retention, so expiry should
-- be a catalog operation rather than a bulk delete. Deleting by age leaves dead
-- tuples behind for autovacuum to reclaim and bloats both heap and indexes once
-- a night; dropping a partition returns the space immediately.
--
-- Three changes are made together because each of them rewrites the table, and
-- doing that once while these tables are still small is far cheaper than doing
-- it later:
--   1. range partitioning on attempted_at, one partition per week
--   2. hashes stored as bytea rather than 64 hex characters, halving both the
--      row and every index entry that carries them
--   3. the succeeded column dropped, since rate limiting moved to Redis and
--      nothing writes or reads a successful attempt any more
--
-- Only failed attempts are carried over: successful rows were never read by any
-- query, and users.last_login already records the same fact.

CREATE OR REPLACE FUNCTION ensure_attempt_partitions(
    parent text,
    from_time timestamptz,
    to_time timestamptz
) RETURNS integer AS $$
DECLARE
    week_start date := date_trunc('week', from_time)::date;
    last_week date := date_trunc('week', to_time)::date;
    created integer := 0;
BEGIN
    WHILE week_start <= last_week LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
            parent || '_p' || to_char(week_start, 'YYYYMMDD'),
            parent,
            week_start,
            week_start + 7);
        created := created + 1;
        week_start := week_start + 7;
    END LOOP;
    RETURN created;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION ensure_attempt_partitions(text, timestamptz, timestamptz) IS
    'Creates weekly partitions covering the given range. Idempotent.';

-- Retention drops whole partitions. A partition is only removed once its entire
-- range is older than the cutoff, so history is kept for the retention period
-- plus at most one partition width.
CREATE OR REPLACE FUNCTION drop_expired_attempt_partitions(
    parent text,
    cutoff timestamptz
) RETURNS integer AS $$
DECLARE
    partition record;
    starts date;
    dropped integer := 0;
BEGIN
    FOR partition IN
        -- Resolved through to_regclass so the parent is matched by identity
        -- rather than by name, which would also match a like-named table in
        -- another schema.
        SELECT child.relname AS name, namespace.nspname AS schema
        FROM pg_inherits
        JOIN pg_class child ON child.oid = pg_inherits.inhrelid
        JOIN pg_namespace namespace ON namespace.oid = child.relnamespace
        WHERE pg_inherits.inhparent = to_regclass(parent)
          -- Excludes the default partition, which has no date in its name and
          -- must never be dropped.
          AND child.relname ~ '_p[0-9]{8}$'
    LOOP
        starts := to_date(right(partition.name, 8), 'YYYYMMDD');
        IF (starts + 7) <= cutoff::date THEN
            EXECUTE format('DROP TABLE %I.%I', partition.schema, partition.name);
            dropped := dropped + 1;
        END IF;
    END LOOP;
    RETURN dropped;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION drop_expired_attempt_partitions(text, timestamptz) IS
    'Drops weekly partitions whose whole range predates the cutoff.';


ALTER TABLE auth_login_attempts RENAME TO auth_login_attempts_legacy;

CREATE TABLE auth_login_attempts (
    id bigint GENERATED ALWAYS AS IDENTITY,
    email_hash bytea NOT NULL,
    ip_hash bytea NOT NULL,
    attempted_at timestamptz NOT NULL DEFAULT now(),
    -- A partitioned table has to carry the partition key in its primary key.
    PRIMARY KEY (id, attempted_at),
    CONSTRAINT ck_auth_login_attempt_email_hash CHECK (octet_length(email_hash) = 32),
    CONSTRAINT ck_auth_login_attempt_ip_hash CHECK (octet_length(ip_hash) = 32)
) PARTITION BY RANGE (attempted_at);

-- Kept for incident lookups only; nothing on a request path reads these.
CREATE INDEX ix_auth_login_attempt_email ON auth_login_attempts (email_hash, attempted_at DESC);
CREATE INDEX ix_auth_login_attempt_ip ON auth_login_attempts (ip_hash, attempted_at DESC);

-- Catches rows whose week was never provisioned. Without it such an insert
-- would fail outright; here it is merely filed in the wrong place and can be
-- swept by age like any other row.
CREATE TABLE auth_login_attempts_default PARTITION OF auth_login_attempts DEFAULT;


ALTER TABLE device_claim_attempts RENAME TO device_claim_attempts_legacy;

CREATE TABLE device_claim_attempts (
    id bigint GENERATED ALWAYS AS IDENTITY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    ip_hash bytea NOT NULL,
    attempted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, attempted_at),
    CONSTRAINT ck_claim_attempt_ip_hash CHECK (octet_length(ip_hash) = 32)
) PARTITION BY RANGE (attempted_at);

CREATE INDEX ix_claim_attempt_user ON device_claim_attempts (user_id, attempted_at DESC);
CREATE INDEX ix_claim_attempt_ip ON device_claim_attempts (ip_hash, attempted_at DESC);

CREATE TABLE device_claim_attempts_default PARTITION OF device_claim_attempts DEFAULT;


-- Enough history to hold the existing rows, plus runway so inserts keep landing
-- in a real partition even if partition maintenance is delayed.
SELECT ensure_attempt_partitions('auth_login_attempts', now() - interval '35 days', now() + interval '28 days');
SELECT ensure_attempt_partitions('device_claim_attempts', now() - interval '35 days', now() + interval '28 days');

INSERT INTO auth_login_attempts (email_hash, ip_hash, attempted_at)
SELECT decode(email_hash, 'hex'), decode(ip_hash, 'hex'), attempted_at
FROM auth_login_attempts_legacy
WHERE succeeded = false;

INSERT INTO device_claim_attempts (user_id, ip_hash, attempted_at)
SELECT user_id, decode(ip_hash, 'hex'), attempted_at
FROM device_claim_attempts_legacy
WHERE succeeded = false;

DROP TABLE auth_login_attempts_legacy;
DROP TABLE device_claim_attempts_legacy;
