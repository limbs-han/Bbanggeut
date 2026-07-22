package com.wj.server.auth.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.util.HexFormat;
import java.util.Locale;

import com.wj.server.auth.persistence.LoginAttemptMapper;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.AuthProperties;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Service
public class LoginAttemptService {
    private final LoginAttemptMapper mapper;
    private final AuthProperties properties;
    private final Clock clock;

    @Autowired
    public LoginAttemptService(LoginAttemptMapper mapper, AuthProperties properties) {
        this(mapper, properties, Clock.systemUTC());
    }

    LoginAttemptService(LoginAttemptMapper mapper, AuthProperties properties, Clock clock) {
        this.mapper = mapper;
        this.properties = properties;
        this.clock = clock;
    }

    @Transactional(readOnly = true)
    public void ensureAllowed(String email, String ipAddress) {
        if (mapper.isRateLimited(
            fingerprint(email), fingerprint(ipAddress),
            clock.instant().minus(properties.loginFailureWindow()),
            properties.loginMaxFailures())) {
            throw new ApiException(
                HttpStatus.TOO_MANY_REQUESTS,
                "LOGIN_RATE_LIMITED",
                "로그인 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.");
        }
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void recordFailure(String email, String ipAddress) {
        mapper.insertAttempt(fingerprint(email), fingerprint(ipAddress), false);
    }

    @Transactional
    public void recordSuccess(String email, String ipAddress) {
        mapper.insertAttempt(fingerprint(email), fingerprint(ipAddress), true);
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
