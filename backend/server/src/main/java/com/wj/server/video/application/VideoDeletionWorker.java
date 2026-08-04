package com.wj.server.video.application;

import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.domain.VideoDeletionJob;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
public class VideoDeletionWorker {
    private static final Logger log = LoggerFactory.getLogger(VideoDeletionWorker.class);
    private final VideoDeletionJobRepository jobs;
    private final ObjectStorageService objectStorageService;

    public VideoDeletionWorker(VideoDeletionJobRepository jobs, ObjectStorageService objectStorageService) {
        this.jobs = jobs;
        this.objectStorageService = objectStorageService;
    }

    @Scheduled(fixedDelayString = "${video.deletion-worker-delay:5000}")
    public void process() {
        for (VideoDeletionJob job : jobs.claim(20)) {
            try {
                objectStorageService.remove(job.storageKey());
                if (job.thumbnailStorageKey() != null) {
                    objectStorageService.remove(job.thumbnailStorageKey());
                }
                // 편집 부산물(분석 캐시·초안·편집본·댓글)도 함께 정리한다.
                // 멱등하므로 실패해 재시도돼도 앞의 삭제가 문제되지 않는다.
                objectStorageService.removeEditData(job.videoId().toString());
                jobs.complete(job);
            } catch (RuntimeException exception) {
                jobs.retry(job.id(), "OBJECT_STORAGE_DELETE_FAILED");
                log.warn("Video deletion will retry: jobId={}, videoId={}, attempts={}",
                    job.id(), job.videoId(), job.attempts());
            }
        }
    }
}
