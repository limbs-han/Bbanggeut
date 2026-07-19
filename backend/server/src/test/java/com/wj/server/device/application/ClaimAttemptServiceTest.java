package com.wj.server.device.application;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.config.DeviceClaimProperties;
import com.wj.server.device.persistence.ClaimAttemptMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class ClaimAttemptServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-17T10:00:00Z");

    @Mock
    private ClaimAttemptMapper mapper;

    private ClaimAttemptService service;

    @BeforeEach
    void setUp() {
        service = new ClaimAttemptService(
            mapper,
            new DeviceClaimProperties(5, Duration.ofMinutes(10)),
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void rejectsWhenAnyRateLimitKeyReachedMaximumFailures() {
        UUID userId = UUID.randomUUID();
        when(mapper.isRateLimited(
            eq(userId), anyString(), anyString(), eq(NOW.minus(Duration.ofMinutes(10))), eq(5)))
            .thenReturn(true);

        assertThatThrownBy(() -> service.ensureAllowed(userId, "WJ-0001", "127.0.0.1"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("CLAIM_RATE_LIMITED");
    }

    @Test
    void storesOnlyFingerprintsForFailedAttempt() {
        UUID userId = UUID.randomUUID();

        service.recordFailure(userId, "WJ-0001", "127.0.0.1");

        verify(mapper).insertAttempt(eq(userId),
            org.mockito.ArgumentMatchers.matches("[0-9a-f]{64}"),
            org.mockito.ArgumentMatchers.matches("[0-9a-f]{64}"), eq(false));
    }
}
