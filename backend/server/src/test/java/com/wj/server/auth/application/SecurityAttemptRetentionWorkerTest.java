package com.wj.server.auth.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;

import com.wj.server.auth.persistence.AttemptRetentionMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;

@ExtendWith(MockitoExtension.class)
class SecurityAttemptRetentionWorkerTest {
    private static final Instant NOW = Instant.parse("2026-07-29T19:15:00Z");

    @Mock
    private AttemptRetentionMapper mapper;

    @Test
    void provisionsAheadAndExpiresBothAttemptTables() {
        var worker = new SecurityAttemptRetentionWorker(mapper, Clock.fixed(NOW, ZoneOffset.UTC));

        worker.maintainPartitions();

        for (String table : new String[] {"auth_login_attempts", "device_claim_attempts"}) {
            verify(mapper).ensurePartitions(eq(table), eq(NOW), eq(NOW.plus(Duration.ofDays(28))));
            verify(mapper).dropExpiredPartitions(eq(table), eq(NOW.minus(Duration.ofDays(30))));
        }
    }

    /**
     * Dropping a partition cannot reclaim rows that landed in the catch-all
     * one, so those still have to be swept by age.
     */
    @Test
    void sweepsRowsStrandedInTheDefaultPartition() {
        var worker = new SecurityAttemptRetentionWorker(mapper, Clock.fixed(NOW, ZoneOffset.UTC));

        worker.maintainPartitions();

        Instant cutoff = NOW.minus(Duration.ofDays(30));
        verify(mapper).sweepLoginDefaultPartition(cutoff);
        verify(mapper).sweepClaimDefaultPartition(cutoff);
    }

    /**
     * A second constructor exists so the schedule can be tested against a fixed
     * clock. Without an explicit injection point Spring cannot choose between
     * them and falls back to looking for a default constructor, which fails
     * only when the application starts rather than in any unit test.
     */
    @Test
    void canBeConstructedByTheContainer() {
        new ApplicationContextRunner()
            .withBean(AttemptRetentionMapper.class, () -> mock(AttemptRetentionMapper.class))
            .withUserConfiguration(SecurityAttemptRetentionWorker.class)
            .run(context -> {
                assertThat(context).hasNotFailed();
                assertThat(context).hasSingleBean(SecurityAttemptRetentionWorker.class);
            });
    }

    @Test
    void auditWritersCanBeConstructedByTheContainer() {
        new ApplicationContextRunner()
            .withBean(com.wj.server.auth.persistence.LoginAttemptMapper.class,
                () -> mock(com.wj.server.auth.persistence.LoginAttemptMapper.class))
            .withBean(com.wj.server.device.persistence.ClaimAttemptMapper.class,
                () -> mock(com.wj.server.device.persistence.ClaimAttemptMapper.class))
            .withUserConfiguration(
                LoginAttemptAuditWriter.class,
                com.wj.server.device.application.ClaimAttemptAuditWriter.class)
            .run(context -> {
                assertThat(context).hasNotFailed();
                assertThat(context).hasSingleBean(LoginAttemptAuditWriter.class);
                assertThat(context)
                    .hasSingleBean(com.wj.server.device.application.ClaimAttemptAuditWriter.class);
            });
    }

    @Test
    void requestsPartitionsThatOutlastAMissedRun() {
        var worker = new SecurityAttemptRetentionWorker(mapper, Clock.fixed(NOW, ZoneOffset.UTC));

        worker.maintainPartitions();

        // Runway has to exceed the daily schedule by a wide margin, or a few
        // skipped runs would push inserts into the default partition.
        verify(mapper).ensurePartitions(
            eq("auth_login_attempts"), any(), eq(NOW.plus(Duration.ofDays(28))));
    }
}
