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
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.TransactionException;

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
    private static final Logger LOGGER = LoggerFactory.getLogger(ClaimAttemptService.class);

    private static final String USER_KEY_PREFIX = "rl:claim:user:";
    private static final String IP_KEY_PREFIX = "rl:claim:ip:";

    private final ClaimAttemptAuditWriter auditWriter;
    private final SlidingWindowRateLimiter rateLimiter;
    private final DeviceClaimProperties properties;

    public ClaimAttemptService(
        ClaimAttemptAuditWriter auditWriter,
        SlidingWindowRateLimiter rateLimiter,
        DeviceClaimProperties properties
    ) {
        this.auditWriter = auditWriter;
        this.rateLimiter = rateLimiter;
        this.properties = properties;
    }

    public SlidingWindowRateLimiter.Reservation reserveOrReject(UUID userId, String ipAddress) {
        SlidingWindowRateLimiter.Reservation reservation = rateLimiter.reserve(
            USER_KEY_PREFIX + userId,
            IP_KEY_PREFIX + fingerprint(ipAddress),
            properties.failureWindow(),
            properties.maxFailures());
        if (reservation == null) {
            throw new ApiException(
                HttpStatus.TOO_MANY_REQUESTS,
                "CLAIM_RATE_LIMITED",
                "기기 등록 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.");
        }
        return reservation;
    }

    /**
     * Releases the account budget after a code was accepted. Earlier failures
     * in the address budget are left alone so that one successful claim cannot
     * clear guessing history from the same address; only this successful
     * reservation is removed.
     */
    public void completeSuccess(SlidingWindowRateLimiter.Reservation reservation) {
        rateLimiter.completeSuccess(reservation);
    }

    /**
     * Best effort audit record. The limit has already been enforced, so a
     * database that cannot take this row must not change the answer the caller
     * receives.
     */
    public void recordFailure(UUID userId, String ipAddress) {
        try {
            auditWriter.write(userId, digest(ipAddress));
        } catch (DataAccessException | TransactionException exception) {
            LOGGER.warn("Could not record a failed device claim attempt", exception);
        }
    }

    private String fingerprint(String value) {
        return HexFormat.of().formatHex(digest(value));
    }

    private byte[] digest(String value) {
        String normalized = value == null ? "unknown" : value.trim().toUpperCase(Locale.ROOT);
        try {
            return MessageDigest.getInstance("SHA-256")
                .digest(normalized.getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }
}
