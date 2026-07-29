package com.wj.server.auth.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Locale;

import com.wj.server.auth.persistence.LoginAttemptMapper;
import com.wj.server.common.api.ApiException;
import com.wj.server.common.ratelimit.SlidingWindowRateLimiter;
import com.wj.server.config.AuthProperties;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

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
    private static final String EMAIL_KEY_PREFIX = "rl:login:email:";
    private static final String IP_KEY_PREFIX = "rl:login:ip:";

    private final LoginAttemptMapper mapper;
    private final SlidingWindowRateLimiter rateLimiter;
    private final AuthProperties properties;

    public LoginAttemptService(
        LoginAttemptMapper mapper,
        SlidingWindowRateLimiter rateLimiter,
        AuthProperties properties
    ) {
        this.mapper = mapper;
        this.rateLimiter = rateLimiter;
        this.properties = properties;
    }

    /**
     * Claims one attempt, or rejects when either bucket is exhausted.
     *
     * <p>Callers must invoke this before checking the password.
     */
    public void reserveOrReject(String email, String ipAddress) {
        boolean admitted = rateLimiter.tryAcquire(
            EMAIL_KEY_PREFIX + fingerprint(email),
            IP_KEY_PREFIX + fingerprint(ipAddress),
            properties.loginFailureWindow(),
            properties.loginMaxFailures());
        if (!admitted) {
            throw new ApiException(
                HttpStatus.TOO_MANY_REQUESTS,
                "LOGIN_RATE_LIMITED",
                "로그인 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.");
        }
    }

    /**
     * Releases the account budget after the password was accepted.
     *
     * <p>The address budget is intentionally left alone: one valid credential
     * must not clear the limit that guards every other account behind the same
     * address.
     */
    public void clearFailures(String email) {
        rateLimiter.reset(EMAIL_KEY_PREFIX + fingerprint(email));
    }

    /**
     * Keeps a durable record of a rejected sign-in for later analysis.
     *
     * <p>This is no longer what enforces the limit, so it runs only for
     * attempts that were admitted and then failed rather than for every
     * request. It stays in its own transaction because the surrounding sign-in
     * transaction is rolled back by the error that follows.
     */
    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void recordFailure(String email, String ipAddress) {
        mapper.insertFailure(fingerprint(email), fingerprint(ipAddress));
    }

    private String fingerprint(String value) {
        String normalized = value == null ? "unknown" : value.trim().toLowerCase(Locale.ROOT);
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(normalized.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }
}
