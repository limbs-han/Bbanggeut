package com.wj.server.video.application;

import java.util.List;
import java.util.UUID;

import com.wj.server.video.persistence.VideoMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * Deletes videos whose retention window expired: flips them to DELETING and
 * enqueues deletion jobs; the existing VideoDeletionWorker removes the objects.
 */
@Component
public class RetentionSweepWorker {
    private static final Logger log = LoggerFactory.getLogger(RetentionSweepWorker.class);
    private static final int BATCH_SIZE = 100;

    private final VideoMapper videoMapper;

    public RetentionSweepWorker(VideoMapper videoMapper) {
        this.videoMapper = videoMapper;
    }

    @Scheduled(fixedDelayString = "${app.retention.sweep-delay:60000}")
    @Transactional
    public void sweep() {
        List<UUID> expired = videoMapper.markRetentionExpiredDeleting(BATCH_SIZE);
        for (UUID videoId : expired) {
            videoMapper.insertDeletionJob(videoId);
        }
        if (!expired.isEmpty()) {
            log.info("Retention sweep queued {} expired videos for deletion", expired.size());
        }
    }
}
