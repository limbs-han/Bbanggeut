package com.wj.server.video.application;

import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

/**
 * 편집 완성본 도착 감지. 완성본은 OS 백그라운드 작업(WorkManager)이 서명된
 * URL로 직접 올리므로 세션이 없고, 그래서 기기 업로드처럼 /complete를 부를
 * 주체가 없다. 서버가 대기 중인 행의 객체를 훑어 도착한 것만 READY로
 * 승격한다.
 *
 * <p>끝내 오지 않은 행은 기존 {@link UploadStateSweepWorker}가 30분 뒤
 * FAILED로 내리고, 보관 만료 경로가 객체까지 정리한다.
 */
@Component
public class EditUploadSweepWorker {
    private static final Logger log = LoggerFactory.getLogger(EditUploadSweepWorker.class);
    private static final int BATCH = 50;

    private final VideoMapper videoMapper;
    private final ObjectStorageService objectStorageService;

    public EditUploadSweepWorker(
        VideoMapper videoMapper, ObjectStorageService objectStorageService
    ) {
        this.videoMapper = videoMapper;
        this.objectStorageService = objectStorageService;
    }

    @Scheduled(fixedDelayString = "${app.upload.edit-sweep-delay-ms:15000}")
    @Transactional
    public void promoteArrivedUploads() {
        for (VideoRow pending : videoMapper.findPendingEditUploads(BATCH)) {
            long size;
            try {
                size = objectStorageService.stat(pending.storageKey()).size();
            } catch (RuntimeException exception) {
                // 아직 도착하지 않았거나 저장소가 일시적으로 불안정하다 —
                // 다음 주기에 다시 본다.
                continue;
            }
            if (size <= 0) {
                continue;
            }
            if (videoMapper.markEditOutputReady(pending.id(), size) == 1) {
                log.info("Edited video upload promoted videoId={} sizeBytes={}",
                    pending.id(), size);
            }
        }
    }
}
