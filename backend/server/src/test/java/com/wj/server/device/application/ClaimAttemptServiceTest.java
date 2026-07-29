package com.wj.server.device.application;

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
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.common.ratelimit.SlidingWindowRateLimiter;
import com.wj.server.config.DeviceClaimProperties;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.DataAccessResourceFailureException;

@ExtendWith(MockitoExtension.class)
class ClaimAttemptServiceTest {
    @Mock
    private ClaimAttemptAuditWriter auditWriter;

    @Mock
    private SlidingWindowRateLimiter rateLimiter;

    private ClaimAttemptService service;

    @BeforeEach
    void setUp() {
        service = new ClaimAttemptService(
            auditWriter, rateLimiter, new DeviceClaimProperties(5, Duration.ofMinutes(10)));
    }

    @Test
    void rejectsWhenAccountOrIpReachedMaximumFailures() {
        UUID userId = UUID.randomUUID();
        when(rateLimiter.tryAcquire(anyString(), anyString(), any(), anyInt())).thenReturn(false);

        assertThatThrownBy(() -> service.reserveOrReject(userId, "127.0.0.1"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("CLAIM_RATE_LIMITED");
    }

    @Test
    void limitsTheGuessingPartyRatherThanTheCodeOrDevice() {
        UUID userId = UUID.randomUUID();
        when(rateLimiter.tryAcquire(anyString(), anyString(), any(), anyInt())).thenReturn(true);

        service.reserveOrReject(userId, "127.0.0.1");

        verify(rateLimiter).tryAcquire(
            eq("rl:claim:user:" + userId),
            matches("rl:claim:ip:[0-9a-f]{64}"),
            eq(Duration.ofMinutes(10)),
            eq(5));
    }

    @Test
    void releasesOnlyTheAccountBudgetOnSuccess() {
        UUID userId = UUID.randomUUID();

        service.clearFailures(userId);

        verify(rateLimiter).reset("rl:claim:user:" + userId);
        verify(rateLimiter, never()).reset(matches("rl:claim:ip:.*"));
    }

    @Test
    void storesRawDigestRatherThanAddressForFailedAttempt() {
        UUID userId = UUID.randomUUID();
        ArgumentCaptor<byte[]> ip = ArgumentCaptor.forClass(byte[].class);

        service.recordFailure(userId, "127.0.0.1");

        verify(auditWriter).write(eq(userId), ip.capture());
        assertThat(ip.getValue()).hasSize(32);
    }

    @Test
    void keepsRejectingClaimsWhenTheAuditWriteFails() {
        UUID userId = UUID.randomUUID();
        doThrow(new DataAccessResourceFailureException("database is down"))
            .when(auditWriter).write(any(), any());

        assertThatCode(() -> service.recordFailure(userId, "127.0.0.1"))
            .doesNotThrowAnyException();
    }
}
