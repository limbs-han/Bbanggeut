package com.wj.server.auth.application;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.List;

import com.wj.server.auth.persistence.AttemptRetentionMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * Keeps attempt history within its retention period.
 *
 * <p>Expiry is a partition drop rather than a delete. Deleting a day of rows
 * leaves dead tuples for autovacuum to reclaim and bloats the indexes along
 * with the heap, all in one nightly burst; dropping the partition returns the
 * space at once and touches only the catalog.
 *
 * <p>The same run also provisions partitions ahead of time, because an insert
 * whose week has no partition would otherwise be filed in the catch-all one.
 */
@Component
public class SecurityAttemptRetentionWorker {
    private static final Logger LOGGER = LoggerFactory.getLogger(SecurityAttemptRetentionWorker.class);

    private static final Duration RETENTION = Duration.ofDays(30);
    /** Far enough ahead that missed runs do not immediately cost a partition. */
    private static final Duration RUNWAY = Duration.ofDays(28);
    private static final List<String> PARTITIONED_TABLES =
        List.of("auth_login_attempts", "device_claim_attempts");

    private final AttemptRetentionMapper mapper;
    private final Clock clock;

    @Autowired
    public SecurityAttemptRetentionWorker(AttemptRetentionMapper mapper) {
        this(mapper, Clock.systemUTC());
    }

    SecurityAttemptRetentionWorker(AttemptRetentionMapper mapper, Clock clock) {
        this.mapper = mapper;
        this.clock = clock;
    }

    @Scheduled(cron = "0 15 4 * * *", zone = "Asia/Seoul")
    @Transactional
    public void maintainPartitions() {
        Instant now = clock.instant();
        Instant cutoff = now.minus(RETENTION);

        int dropped = 0;
        for (String table : PARTITIONED_TABLES) {
            mapper.ensurePartitions(table, now, now.plus(RUNWAY));
            dropped += mapper.dropExpiredPartitions(table, cutoff);
        }

        // Only ever non-zero if maintenance stopped running long enough for the
        // provisioned weeks to run out, so it is worth noticing.
        int stragglers = mapper.sweepLoginDefaultPartition(cutoff)
            + mapper.sweepClaimDefaultPartition(cutoff);
        if (stragglers > 0) {
            LOGGER.warn("Swept {} expired attempt rows from a default partition", stragglers);
        }
        LOGGER.info("Attempt retention complete, dropped {} expired partitions", dropped);
    }
}
