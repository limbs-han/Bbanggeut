package com.wj.server.video.application;

import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.domain.VideoDeletionJob;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
public class VideoDeletionWorker {
    private static final Logger log = LoggerFactory.getLogger(VideoDeletionWorker.class);
    private final VideoDeletionJobRepository jobs;
    private final ObjectStorageService objectStorageService;

    /**
     * 한 작업을 몇 번까지 시도하는가. 재시도 간격이 뒤로 갈수록 5분이라 20회는
     * 약 1시간 40분이다 — 일시적인 저장소 장애는 넉넉히 덮고, 절대 성공할 수
     * 없는 작업은 그 안에서 멈춘다.
     */
    private final int maxAttempts;

    public VideoDeletionWorker(
        VideoDeletionJobRepository jobs,
        ObjectStorageService objectStorageService,
        @Value("${video.deletion-max-attempts:20}") int maxAttempts
    ) {
        this.jobs = jobs;
        this.objectStorageService = objectStorageService;
        this.maxAttempts = maxAttempts;
    }

    @Scheduled(fixedDelayString = "${video.deletion-worker-delay:5000}")
    public void process() {
        for (VideoDeletionJob job : jobs.claim(20, maxAttempts)) {
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
                report(job, exception);
            }
        }
    }

    /**
     * 실패를 기록한다.
     *
     * <p><b>예외를 함께 남기는 것이 핵심이다.</b> 예전에는 경고 한 줄만 찍고
     * 예외를 버려서, 실서버에서 같은 작업이 485회 실패하는 동안에도 무엇이
     * 막고 있는지 로그로 알 수 없었다 — 백엔드 자격증명에 편집 버킷 권한이
     * 없어 목록 조회가 403으로 막히고 있었는데, 그 사실이 어디에도 남지 않았다.
     *
     * <p>상한에 닿으면 더 이상 집히지 않으므로 사람이 봐야 한다는 뜻으로
     * ERROR로 올린다. 그 뒤로는 조용하다 — 5분마다 같은 줄을 영원히 남기는
     * 것은 알림이 아니라 소음이다.
     */
    private void report(VideoDeletionJob job, RuntimeException exception) {
        if (job.attempts() >= maxAttempts) {
            log.error("Video deletion gave up after {} attempts — 저장소에 남은 객체를 "
                    + "사람이 확인해야 합니다: jobId={}, videoId={}",
                job.attempts(), job.id(), job.videoId(), exception);
            return;
        }
        log.warn("Video deletion will retry: jobId={}, videoId={}, attempts={}/{}",
            job.id(), job.videoId(), job.attempts(), maxAttempts, exception);
    }
}
