package com.wj.server.auth.application;

import java.time.Clock;
import java.time.Duration;

import com.wj.server.auth.persistence.LoginAttemptMapper;
import com.wj.server.device.persistence.ClaimAttemptMapper;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

@Component
public class SecurityAttemptCleanupWorker {
    private static final Duration RETENTION = Duration.ofDays(30);

    private final LoginAttemptMapper loginAttemptMapper;
    private final ClaimAttemptMapper claimAttemptMapper;
    private final Clock clock;

    public SecurityAttemptCleanupWorker(
        LoginAttemptMapper loginAttemptMapper,
        ClaimAttemptMapper claimAttemptMapper
    ) {
        this.loginAttemptMapper = loginAttemptMapper;
        this.claimAttemptMapper = claimAttemptMapper;
        this.clock = Clock.systemUTC();
    }

    @Scheduled(cron = "0 15 4 * * *", zone = "Asia/Seoul")
    @Transactional
    public void deleteExpiredAttempts() {
        var before = clock.instant().minus(RETENTION);
        loginAttemptMapper.deleteOlderThan(before);
        claimAttemptMapper.deleteOlderThan(before);
    }
}
