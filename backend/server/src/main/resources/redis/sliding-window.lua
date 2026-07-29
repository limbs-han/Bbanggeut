-- Sliding window rate limiter over two buckets that share one budget.
--
-- A credential guess is limited both by the identity it targets (account) and
-- by the party doing the guessing (IP). Either bucket reaching the limit
-- rejects the attempt, so the two are evaluated and recorded together. Doing
-- that inside one script keeps the whole decision atomic: Redis executes a
-- script to completion before serving another client, so no concurrent caller
-- can observe a count between the check and the record.
--
-- KEYS[1] identity bucket, KEYS[2] address bucket
-- ARGV[1] window in milliseconds
-- ARGV[2] maximum attempts per window
-- ARGV[3] unique member id for this attempt
--
-- Returns 1 when the attempt was admitted and recorded, 0 when rejected.

local window = tonumber(ARGV[1])
local limit = tonumber(ARGV[2])
local member = ARGV[3]

-- Server time keeps the window correct even when application clocks drift.
local time = redis.call('TIME')
local now = time[1] * 1000 + math.floor(time[2] / 1000)
local cutoff = now - window

-- Drop expired entries first so the counts below describe the live window
-- only. This is what makes the window sliding rather than fixed: there is no
-- shared reset instant that an attacker could straddle.
redis.call('ZREMRANGEBYSCORE', KEYS[1], 0, cutoff)
redis.call('ZREMRANGEBYSCORE', KEYS[2], 0, cutoff)

if redis.call('ZCARD', KEYS[1]) >= limit then
    return 0
end
if redis.call('ZCARD', KEYS[2]) >= limit then
    return 0
end

-- Record before the caller verifies the credential. A rejected attempt must
-- never be cheaper than an accepted one, otherwise the expensive hash check
-- can be reached by simply issuing requests concurrently.
redis.call('ZADD', KEYS[1], now, member)
redis.call('ZADD', KEYS[2], now, member)

-- Entries older than the window are already useless, so let Redis reclaim the
-- keys instead of running a cleanup job.
redis.call('PEXPIRE', KEYS[1], window)
redis.call('PEXPIRE', KEYS[2], window)

return 1
