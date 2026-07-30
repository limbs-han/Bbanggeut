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
    private static final RedisScript<Long> COMPLETE_SUCCESS = RedisScript.of(
        new ClassPathResource("redis/complete-successful-attempt.lua"), Long.class);

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
    public Reservation reserve(String identityKey, String addressKey, Duration window, int limit) {
        String memberId = UUID.randomUUID().toString();
        Reservation reservation = new Reservation(identityKey, addressKey, memberId);
        try {
            Long admitted = redis.execute(
                SLIDING_WINDOW,
                List.of(identityKey, addressKey),
                Long.toString(window.toMillis()),
                Integer.toString(limit),
                memberId);
            return Long.valueOf(0L).equals(admitted) ? null : reservation;
        } catch (DataAccessException exception) {
            LOGGER.warn(
                "Rate limiter unavailable, allowing attempt identityKey={} addressKey={}",
                identityKey, addressKey, exception);
            return reservation;
        }
    }

    /**
     * Convenience API for callers that do not need to undo a successful
     * reservation.
     */
    public boolean tryAcquire(String identityKey, String addressKey, Duration window, int limit) {
        return reserve(identityKey, addressKey, window, limit) != null;
    }

    /**
     * Clears earlier failures for the accepted identity and removes only the
     * successful request from the shared address bucket.
     *
     * <p>The address bucket may contain failed attempts against other accounts,
     * so deleting the whole key would let one valid credential erase another
     * user's guessing history. The Lua script performs both operations
     * atomically and removes the address member associated with this exact
     * reservation.
     */
    public void completeSuccess(Reservation reservation) {
        try {
            redis.execute(
                COMPLETE_SUCCESS,
                List.of(reservation.identityKey(), reservation.addressKey()),
                reservation.memberId());
        } catch (DataAccessException exception) {
            LOGGER.warn(
                "Rate limiter unavailable, could not complete successful reservation "
                    + "identityKey={} addressKey={}",
                reservation.identityKey(), reservation.addressKey(), exception);
        }
    }

    public record Reservation(String identityKey, String addressKey, String memberId) {
    }
}
