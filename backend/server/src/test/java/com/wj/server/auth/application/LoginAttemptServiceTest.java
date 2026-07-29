package com.wj.server.auth.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.matches;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Duration;

import com.wj.server.auth.persistence.LoginAttemptMapper;
import com.wj.server.common.api.ApiException;
import com.wj.server.common.ratelimit.SlidingWindowRateLimiter;
import com.wj.server.config.AuthProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class LoginAttemptServiceTest {
    private static final AuthProperties PROPERTIES = new AuthProperties(
        Duration.ofMinutes(15), Duration.ofDays(14), "test-signing-key-at-least-thirty-two-bytes",
        5, Duration.ofMinutes(10));

    @Mock
    private LoginAttemptMapper mapper;

    @Mock
    private SlidingWindowRateLimiter rateLimiter;

    @Test
    void rejectsWhenLimiterRefusesTheAttempt() {
        LoginAttemptService service = new LoginAttemptService(mapper, rateLimiter, PROPERTIES);
        when(rateLimiter.tryAcquire(anyString(), anyString(), any(), anyInt())).thenReturn(false);

        assertThatThrownBy(() -> service.reserveOrReject("USER@example.com", "203.0.113.1"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("LOGIN_RATE_LIMITED");
    }

    @Test
    void claimsTheAttemptBeforeAnyPasswordCheck() {
        LoginAttemptService service = new LoginAttemptService(mapper, rateLimiter, PROPERTIES);
        when(rateLimiter.tryAcquire(anyString(), anyString(), any(), anyInt())).thenReturn(true);

        service.reserveOrReject("user@example.com", "203.0.113.1");

        verify(rateLimiter).tryAcquire(
            matches("rl:login:email:[0-9a-f]{64}"),
            matches("rl:login:ip:[0-9a-f]{64}"),
            eq(Duration.ofMinutes(10)),
            eq(5));
        // Nothing is written to the database on the decision path.
        verify(mapper, never()).insertFailure(anyString(), anyString());
    }

    @Test
    void normalizesEmailCaseSoTheBudgetCannotBeSidestepped() {
        LoginAttemptService service = new LoginAttemptService(mapper, rateLimiter, PROPERTIES);
        when(rateLimiter.tryAcquire(anyString(), anyString(), any(), anyInt())).thenReturn(true);
        ArgumentCaptor<String> emailKey = ArgumentCaptor.forClass(String.class);

        service.reserveOrReject("User@Example.com", "203.0.113.1");
        service.reserveOrReject("  user@example.com  ", "203.0.113.1");

        verify(rateLimiter, org.mockito.Mockito.times(2))
            .tryAcquire(emailKey.capture(), anyString(), any(), anyInt());
        assertThat(emailKey.getAllValues().get(0)).isEqualTo(emailKey.getAllValues().get(1));
    }

    @Test
    void releasesOnlyTheAccountBudgetOnSuccess() {
        LoginAttemptService service = new LoginAttemptService(mapper, rateLimiter, PROPERTIES);

        service.clearFailures("user@example.com");

        verify(rateLimiter).reset(matches("rl:login:email:[0-9a-f]{64}"));
        verify(rateLimiter, never()).reset(matches("rl:login:ip:.*"));
    }

    @Test
    void storesOnlyFingerprintsForTheAuditRecord() {
        LoginAttemptService service = new LoginAttemptService(mapper, rateLimiter, PROPERTIES);

        service.recordFailure("user@example.com", "203.0.113.1");

        verify(mapper).insertFailure(matches("[0-9a-f]{64}"), matches("[0-9a-f]{64}"));
    }
}
