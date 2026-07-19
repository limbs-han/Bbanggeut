package com.wj.server.device.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.util.HexFormat;
import java.util.Locale;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.config.DeviceClaimProperties;
import com.wj.server.device.persistence.ClaimAttemptMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Service
public class ClaimAttemptService {
    private final ClaimAttemptMapper mapper;
    private final DeviceClaimProperties properties;
    private final Clock clock;

    @Autowired
    public ClaimAttemptService(ClaimAttemptMapper mapper, DeviceClaimProperties properties) {
        this(mapper, properties, Clock.systemUTC());
    }

    ClaimAttemptService(ClaimAttemptMapper mapper, DeviceClaimProperties properties, Clock clock) {
        this.mapper = mapper;
        this.properties = properties;
        this.clock = clock;
    }

    @Transactional(readOnly = true)
    public void ensureAllowed(UUID userId, String serialNumber, String ipAddress) {
        if (mapper.isRateLimited(
            userId,
            fingerprint(serialNumber),
            fingerprint(ipAddress),
            clock.instant().minus(properties.failureWindow()),
            properties.maxFailures())) {
            throw new ApiException(
                HttpStatus.TOO_MANY_REQUESTS,
                "CLAIM_RATE_LIMITED",
                "기기 등록 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.");
        }
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void recordFailure(UUID userId, String serialNumber, String ipAddress) {
        mapper.insertAttempt(userId, fingerprint(serialNumber), fingerprint(ipAddress), false);
    }

    @Transactional
    public void recordSuccess(UUID userId, String serialNumber, String ipAddress) {
        mapper.insertAttempt(userId, fingerprint(serialNumber), fingerprint(ipAddress), true);
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
