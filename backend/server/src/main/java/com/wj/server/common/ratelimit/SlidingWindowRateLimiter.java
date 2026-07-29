package com.wj.server.common.ratelimit;

import java.time.Duration;
import java.util.List;
import java.util.UUID;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.io.ClassPathResource;
import org.springframework.dao.DataAccessException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.RedisScript;
import org.springframework.stereotype.Component;

/**
 * Sliding window limiter for credential guessing, backed by Redis.
 *
 * <p>The decision has to be atomic with the record it is based on. A limiter
 * that counts first and writes afterwards lets concurrent requests all observe
 * the same pre-limit count and pass together, which is exactly the traffic
 * shape an attacker produces. Redis runs a script to completion before serving
 * the next client, so the whole check-and-record sequence is indivisible
 * without holding a lock and without making callers wait on each other.
 *
 * <p>Redis being unavailable degrades to allowing the request. Rejecting
 * instead would turn a cache outage into a total sign-in outage; the volumetric
 * limit in the reverse proxy stays in force either way.
 */
@Component
public class SlidingWindowRateLimiter {
    private static final Logger LOGGER = LoggerFactory.getLogger(SlidingWindowRateLimiter.class);

    private static final RedisScript<Long> SLIDING_WINDOW = RedisScript.of(
        new ClassPathResource("redis/sliding-window.lua"), Long.class);

    private final StringRedisTemplate redis;

    public SlidingWindowRateLimiter(StringRedisTemplate redis) {
        this.redis = redis;
    }

    /**
     * Admits and records one attempt when neither bucket has reached the limit.
     *
     * <p>Both keys are evaluated together because a guess is limited by the
     * identity it targets and by the address it comes from. On a Redis cluster
     * the two keys would need a common hash slot; this deployment is a single
     * node, so they are kept readable instead.
     *
     * @return true when the attempt may proceed
     */
    public boolean tryAcquire(String identityKey, String addressKey, Duration window, int limit) {
        try {
            Long admitted = redis.execute(
                SLIDING_WINDOW,
                List.of(identityKey, addressKey),
                Long.toString(window.toMillis()),
                Integer.toString(limit),
                UUID.randomUUID().toString());
            return !Long.valueOf(0L).equals(admitted);
        } catch (DataAccessException exception) {
            LOGGER.warn(
                "Rate limiter unavailable, allowing attempt identityKey={} addressKey={}",
                identityKey, addressKey, exception);
            return true;
        }
    }

    /**
     * Forgets the attempts recorded for one bucket.
     *
     * <p>Only ever called for an identity bucket. Clearing the address bucket
     * would let anyone holding a single valid credential wipe the budget that
     * limits guessing against every other account from that address.
     */
    public void reset(String key) {
        try {
            redis.delete(key);
        } catch (DataAccessException exception) {
            LOGGER.warn("Rate limiter unavailable, keeping recorded attempts key={}", key, exception);
        }
    }
}
