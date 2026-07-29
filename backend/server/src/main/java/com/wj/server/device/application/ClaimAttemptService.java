package com.wj.server.device.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Locale;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.common.ratelimit.SlidingWindowRateLimiter;
import com.wj.server.config.DeviceClaimProperties;
import com.wj.server.device.persistence.ClaimAttemptMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Rate limits claim attempts per account and per IP. A wrong registration code
 * does not belong to any device, so the limit is applied to the guessing party
 * (account/IP), never to a code or device.
 *
 * <p>As with sign-in, the attempt is claimed before the submitted code is
 * looked up so that concurrent requests cannot share one pre-limit count.
 */
@Service
public class ClaimAttemptService {
    private static final String USER_KEY_PREFIX = "rl:claim:user:";
    private static final String IP_KEY_PREFIX = "rl:claim:ip:";

    private final ClaimAttemptMapper mapper;
    private final SlidingWindowRateLimiter rateLimiter;
    private final DeviceClaimProperties properties;

    public ClaimAttemptService(
        ClaimAttemptMapper mapper,
        SlidingWindowRateLimiter rateLimiter,
        DeviceClaimProperties properties
    ) {
        this.mapper = mapper;
        this.rateLimiter = rateLimiter;
        this.properties = properties;
    }

    public void reserveOrReject(UUID userId, String ipAddress) {
        boolean admitted = rateLimiter.tryAcquire(
            USER_KEY_PREFIX + userId,
            IP_KEY_PREFIX + fingerprint(ipAddress),
            properties.failureWindow(),
            properties.maxFailures());
        if (!admitted) {
            throw new ApiException(
                HttpStatus.TOO_MANY_REQUESTS,
                "CLAIM_RATE_LIMITED",
                "기기 등록 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.");
        }
    }

    /**
     * Releases the account budget after a code was accepted. The address budget
     * is left alone so that one successful claim cannot clear the limit that
     * guards guessing from the same address.
     */
    public void clearFailures(UUID userId) {
        rateLimiter.reset(USER_KEY_PREFIX + userId);
    }

    /**
     * Durable record of a rejected claim, kept for incident analysis rather
     * than for enforcement. Runs in its own transaction because the claim
     * transaction is rolled back by the rejection that follows.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void recordFailure(UUID userId, String ipAddress) {
        mapper.insertFailure(userId, fingerprint(ipAddress));
    }

    private String fingerprint(String value) {
        String normalized = value == null ? "unknown" : value.trim().toUpperCase(Locale.ROOT);
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest(normalized.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }
}
