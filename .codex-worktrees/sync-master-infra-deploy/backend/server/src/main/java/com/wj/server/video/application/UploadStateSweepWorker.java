package com.wj.server.video.application;

import java.time.Clock;
import java.time.Duration;
import java.util.List;
import java.util.UUID;

import com.wj.server.video.persistence.VideoMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * Closes upload reservations that never reached /complete. A later request
 * with the same event id can retry the FAILED row and receive a fresh URL.
 */
@Component
public class UploadStateSweepWorker {
    private static final Logger log = LoggerFactory.getLogger(UploadStateSweepWorker.class);
    private static final int BATCH_SIZE = 100;

    private final VideoMapper videoMapper;
    private final Duration staleAfter;
    private final Clock clock;

    @Autowired
    public UploadStateSweepWorker(
        VideoMapper videoMapper,
        @Value("${app.upload.stale-after:30m}") Duration staleAfter
    ) {
        this(videoMapper, staleAfter, Clock.systemUTC());
    }

    UploadStateSweepWorker(VideoMapper videoMapper, Duration staleAfter, Clock clock) {
        if (staleAfter == null || staleAfter.isZero() || staleAfter.isNegative()) {
            throw new IllegalArgumentException("app.upload.stale-after must be positive");
        }
        this.videoMapper = videoMapper;
        this.staleAfter = staleAfter;
        this.clock = clock;
    }

    @Scheduled(fixedDelayString = "${app.upload.sweep-delay-ms:60000}")
    @Transactional
    public void sweep() {
        List<UUID> failed = videoMapper.markStaleUploadsFailed(
            clock.instant().minus(staleAfter), BATCH_SIZE);
        if (!failed.isEmpty()) {
            log.info("Marked {} stale video uploads as FAILED", failed.size());
        }
    }
}
