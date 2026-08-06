package com.wj.server.video.application;

import java.util.List;

import com.wj.server.video.domain.VideoDeletionJob;
import com.wj.server.video.persistence.VideoDeletionJobMapper;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

@Repository
public class VideoDeletionJobRepository {
    private final VideoDeletionJobMapper mapper;

    public VideoDeletionJobRepository(VideoDeletionJobMapper mapper) {
        this.mapper = mapper;
    }

    @Transactional
    public List<VideoDeletionJob> claim(int limit, int maxAttempts) {
        return mapper.claim(limit, maxAttempts);
    }

    @Transactional
    public void complete(VideoDeletionJob job) {
        mapper.markVideoDeleted(job.videoId());
        mapper.complete(job.id());
    }

    @Transactional
    public void retry(long jobId, String errorCode) {
        mapper.retry(jobId, errorCode);
    }
}
