-- Completes a reservation after the protected credential was accepted.
--
-- KEYS[1] identity bucket, KEYS[2] shared address bucket
-- ARGV[1] member id returned with the reservation
--
-- A success resets earlier failures for that identity, but must not erase
-- failures against other identities from the same address. Only this request's
-- provisional member is removed from the shared bucket.

redis.call('DEL', KEYS[1])
return redis.call('ZREM', KEYS[2], ARGV[1])
