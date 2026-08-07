package com.wj.server.auth.application;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;

import com.wj.server.auth.persistence.LoginAttemptMapper;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.AuthProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class LoginAttemptServiceTest {
    @Mock
    private LoginAttemptMapper mapper;

    @Test
    void blocksAfterConfiguredFailureThreshold() {
        Instant now = Instant.parse("2026-07-20T10:00:00Z");
        AuthProperties properties = new AuthProperties(
            Duration.ofMinutes(15), Duration.ofDays(14), "test-signing-key-at-least-thirty-two-bytes",
            5, Duration.ofMinutes(10));
        LoginAttemptService service = new LoginAttemptService(
            mapper, properties, Clock.fixed(now, ZoneOffset.UTC));
        when(mapper.isRateLimited(
            org.mockito.ArgumentMatchers.matches("[0-9a-f]{64}"),
            org.mockito.ArgumentMatchers.matches("[0-9a-f]{64}"),
            org.mockito.ArgumentMatchers.eq(now.minus(Duration.ofMinutes(10))),
            org.mockito.ArgumentMatchers.eq(5))).thenReturn(true);

        assertThatThrownBy(() -> service.ensureAllowed("USER@example.com", "203.0.113.1"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("LOGIN_RATE_LIMITED");
    }

    @Test
    void storesOnlyFingerprintsForFailure() {
        AuthProperties properties = new AuthProperties(
            Duration.ofMinutes(15), Duration.ofDays(14), "test-signing-key-at-least-thirty-two-bytes",
            5, Duration.ofMinutes(10));
        LoginAttemptService service = new LoginAttemptService(mapper, properties, Clock.systemUTC());

        service.recordFailure("user@example.com", "203.0.113.1");

        verify(mapper).insertAttempt(
            org.mockito.ArgumentMatchers.matches("[0-9a-f]{64}"),
            org.mockito.ArgumentMatchers.matches("[0-9a-f]{64}"),
            org.mockito.ArgumentMatchers.eq(false));
    }
}
