package com.wj.server.video.application;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.config.SubscriptionProperties;
import com.wj.server.video.domain.VideoEditRow;
import com.wj.server.video.persistence.VideoEditMapper;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

@Repository
public class VideoEditJobRepository {
    private final VideoEditMapper mapper;
    private final SubscriptionProperties subscriptionProperties;

    public VideoEditJobRepository(VideoEditMapper mapper, SubscriptionProperties subscriptionProperties) {
        this.mapper = mapper;
        this.subscriptionProperties = subscriptionProperties;
    }

    @Transactional
    public Optional<VideoEditRow> claimNext() {
        return mapper.claimNext();
    }

    @Transactional
    public void complete(
        VideoEditRow job,
        UUID resultVideoId,
        String storageKey,
        long sizeBytes,
        String checksumSha256,
        Instant capturedStartAt,
        Instant capturedEndAt
    ) {
        long durationMs = job.endMs() - job.startMs();
        if (mapper.insertResultVideo(
            resultVideoId, job.deviceId(), job.requestedBy(), job.title(), storageKey,
            sizeBytes, checksumSha256, durationMs, capturedStartAt, capturedEndAt,
            subscriptionProperties.premiumRetentionDays()) != 1) {
            throw new IllegalStateException("Result video was not inserted");
        }
        if (mapper.complete(job.id(), resultVideoId) != 1) {
            throw new IllegalStateException("Video edit was not completed");
        }
    }

    @Transactional
    public void fail(UUID editId, String errorCode) {
        mapper.fail(editId, errorCode);
    }
}
