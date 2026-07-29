package com.wj.server.auth.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.matches;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Duration;

import com.wj.server.common.api.ApiException;
import com.wj.server.common.ratelimit.SlidingWindowRateLimiter;
import com.wj.server.config.AuthProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.DataAccessResourceFailureException;

@ExtendWith(MockitoExtension.class)
class LoginAttemptServiceTest {
    private static final AuthProperties PROPERTIES = new AuthProperties(
        Duration.ofMinutes(15), Duration.ofDays(14), "test-signing-key-at-least-thirty-two-bytes",
        5, Duration.ofMinutes(10));

    @Mock
    private LoginAttemptAuditWriter auditWriter;

    @Mock
    private SlidingWindowRateLimiter rateLimiter;

    @Test
    void rejectsWhenLimiterRefusesTheAttempt() {
        LoginAttemptService service = new LoginAttemptService(auditWriter, rateLimiter, PROPERTIES);
        when(rateLimiter.tryAcquire(anyString(), anyString(), any(), anyInt())).thenReturn(false);

        assertThatThrownBy(() -> service.reserveOrReject("USER@example.com", "203.0.113.1"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("LOGIN_RATE_LIMITED");
    }

    @Test
    void claimsTheAttemptBeforeAnyPasswordCheck() {
        LoginAttemptService service = new LoginAttemptService(auditWriter, rateLimiter, PROPERTIES);
        when(rateLimiter.tryAcquire(anyString(), anyString(), any(), anyInt())).thenReturn(true);

        service.reserveOrReject("user@example.com", "203.0.113.1");

        verify(rateLimiter).tryAcquire(
            matches("rl:login:email:[0-9a-f]{64}"),
            matches("rl:login:ip:[0-9a-f]{64}"),
            eq(Duration.ofMinutes(10)),
            eq(5));
        // Nothing is written to the database on the decision path.
        verify(auditWriter, never()).write(any(), any());
    }

    @Test
    void normalizesEmailCaseSoTheBudgetCannotBeSidestepped() {
        LoginAttemptService service = new LoginAttemptService(auditWriter, rateLimiter, PROPERTIES);
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
        LoginAttemptService service = new LoginAttemptService(auditWriter, rateLimiter, PROPERTIES);

        service.clearFailures("user@example.com");

        verify(rateLimiter).reset(matches("rl:login:email:[0-9a-f]{64}"));
        verify(rateLimiter, never()).reset(matches("rl:login:ip:.*"));
    }

    @Test
    void storesRawDigestsRatherThanIdentifiersForTheAuditRecord() {
        LoginAttemptService service = new LoginAttemptService(auditWriter, rateLimiter, PROPERTIES);
        ArgumentCaptor<byte[]> email = ArgumentCaptor.forClass(byte[].class);
        ArgumentCaptor<byte[]> ip = ArgumentCaptor.forClass(byte[].class);

        service.recordFailure("user@example.com", "203.0.113.1");

        verify(auditWriter).write(email.capture(), ip.capture());
        assertThat(email.getValue()).hasSize(32);
        assertThat(ip.getValue()).hasSize(32);
    }

    /**
     * The limit has already been enforced by the time this runs, so a database
     * that cannot take the audit row must not turn a rejected password into a
     * server error.
     */
    @Test
    void keepsRejectingCredentialsWhenTheAuditWriteFails() {
        LoginAttemptService service = new LoginAttemptService(auditWriter, rateLimiter, PROPERTIES);
        doThrow(new DataAccessResourceFailureException("database is down"))
            .when(auditWriter).write(any(), any());

        assertThatCode(() -> service.recordFailure("user@example.com", "203.0.113.1"))
            .doesNotThrowAnyException();
    }
}
