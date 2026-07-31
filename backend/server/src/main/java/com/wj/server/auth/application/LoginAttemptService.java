package com.wj.server.auth.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Locale;

import com.wj.server.common.api.ApiException;
import com.wj.server.common.ratelimit.SlidingWindowRateLimiter;
import com.wj.server.config.AuthProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.TransactionException;

/**
 * Limits sign-in attempts per account and per address.
 *
 * <p>The limit is claimed before the password is verified rather than recorded
 * after it fails. Verification is deliberately slow, so a check that only
 * counted earlier failures would let every concurrent request through on the
 * same count and spend the hashing cost anyway.
 */
@Service
public class LoginAttemptService {
    private static final Logger LOGGER = LoggerFactory.getLogger(LoginAttemptService.class);

    private static final String EMAIL_KEY_PREFIX = "rl:login:email:";
    private static final String IP_KEY_PREFIX = "rl:login:ip:";

    private final LoginAttemptAuditWriter auditWriter;
    private final SlidingWindowRateLimiter rateLimiter;
    private final AuthProperties properties;

    public LoginAttemptService(
        LoginAttemptAuditWriter auditWriter,
        SlidingWindowRateLimiter rateLimiter,
        AuthProperties properties
    ) {
        this.auditWriter = auditWriter;
        this.rateLimiter = rateLimiter;
        this.properties = properties;
    }

    /**
     * Claims one attempt, or rejects when either bucket is exhausted.
     *
     * <p>Callers must invoke this before checking the password.
     */
    public SlidingWindowRateLimiter.Reservation reserveOrReject(String email, String ipAddress) {
        SlidingWindowRateLimiter.Reservation reservation = rateLimiter.reserve(
            EMAIL_KEY_PREFIX + fingerprint(email),
            IP_KEY_PREFIX + fingerprint(ipAddress),
            properties.loginFailureWindow(),
            properties.loginMaxFailures());
        if (reservation == null) {
            throw new ApiException(
                HttpStatus.TOO_MANY_REQUESTS,
                "LOGIN_RATE_LIMITED",
                "로그인 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.");
        }
        return reservation;
    }

    /**
     * Releases the account budget after the password was accepted.
     *
     * <p>Earlier failures in the address budget are intentionally left alone:
     * one valid credential must not clear the limit that guards every other
     * account behind the same address. Only this successful reservation is
     * removed from that shared bucket.
     */
    public void completeSuccess(SlidingWindowRateLimiter.Reservation reservation) {
        rateLimiter.completeSuccess(reservation);
    }

    /**
     * Keeps a durable record of a rejected sign-in for later analysis.
     *
     * <p>Best effort on purpose. The limit is already enforced by this point,
     * so a database that cannot take the audit row must not turn a rejected
     * password into a server error for the user.
     */
    public void recordFailure(String email, String ipAddress) {
        try {
            auditWriter.write(digest(email), digest(ipAddress));
        } catch (DataAccessException | TransactionException exception) {
            LOGGER.warn("Could not record a failed sign-in attempt", exception);
        }
    }

    private String fingerprint(String value) {
        return HexFormat.of().formatHex(digest(value));
    }

    private byte[] digest(String value) {
        String normalized = value == null ? "unknown" : value.trim().toLowerCase(Locale.ROOT);
        try {
            return MessageDigest.getInstance("SHA-256")
                .digest(normalized.getBytes(StandardCharsets.UTF_8));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }
}
