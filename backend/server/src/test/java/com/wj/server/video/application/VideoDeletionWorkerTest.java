package com.wj.server.video.application;

import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.util.List;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.domain.VideoDeletionJob;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.http.HttpStatus;

@ExtendWith(MockitoExtension.class)
class VideoDeletionWorkerTest {
    private static final int MAX_ATTEMPTS = 20;

    @Mock
    private VideoDeletionJobRepository jobs;
    @Mock
    private ObjectStorageService storage;

    @Test
    void deletesOriginalAndThumbnailThenCompletesJob() {
        UUID videoId = UUID.randomUUID();
        VideoDeletionJob job = new VideoDeletionJob(1, videoId, "video.mp4", "thumb.jpg", 1);
        when(jobs.claim(20, MAX_ATTEMPTS)).thenReturn(List.of(job));

        new VideoDeletionWorker(jobs, storage, MAX_ATTEMPTS).process();

        verify(storage).remove("video.mp4");
        verify(storage).remove("thumb.jpg");
        // 편집 부산물(분석 캐시·초안·편집본)도 같은 잡에서 정리된다.
        verify(storage).removeEditData(videoId.toString());
        verify(jobs).complete(job);
    }

    @Test
    void storageFailureLeavesRetryableJob() {
        VideoDeletionJob job = new VideoDeletionJob(2, UUID.randomUUID(), "video.mp4", null, 2);
        when(jobs.claim(20, MAX_ATTEMPTS)).thenReturn(List.of(job));
        doThrow(new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "OBJECT_STORAGE_UNAVAILABLE", "failed"))
            .when(storage).remove("video.mp4");

        new VideoDeletionWorker(jobs, storage, MAX_ATTEMPTS).process();

        verify(jobs).retry(2, "OBJECT_STORAGE_DELETE_FAILED");
    }

    /**
     * 상한을 넘긴 작업은 더 이상 집히지 않는다.
     *
     * <p>상한이 없던 동안 실서버의 삭제 작업 두 건이 각각 485회·470회까지
     * 돌면서 5분마다 같은 경고를 남겼다 — 권한이 없어 절대 성공할 수 없는
     * 작업이었다. 집는 쪽에서 막는 것이 상한의 실제 구현이므로, 워커가 그
     * 값을 그대로 넘기는지 못박는다.
     */
    @Test
    void claimIsBoundedByTheAttemptLimit() {
        when(jobs.claim(20, MAX_ATTEMPTS)).thenReturn(List.of());

        new VideoDeletionWorker(jobs, storage, MAX_ATTEMPTS).process();

        verify(jobs).claim(20, MAX_ATTEMPTS);
        verifyNoInteractions(storage);
    }

    @Test
    void editDataFailureLeavesRetryableJob() {
        UUID videoId = UUID.randomUUID();
        VideoDeletionJob job = new VideoDeletionJob(3, videoId, "video.mp4", null, 1);
        when(jobs.claim(20, MAX_ATTEMPTS)).thenReturn(List.of(job));
        doThrow(new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "OBJECT_STORAGE_UNAVAILABLE", "failed"))
            .when(storage).removeEditData(videoId.toString());

        new VideoDeletionWorker(jobs, storage, MAX_ATTEMPTS).process();

        // 원본은 지워졌어도 편집 데이터가 남았으면 잡을 끝내지 않는다 —
        // remove는 멱등하므로 재시도가 안전하다.
        verify(jobs).retry(3, "OBJECT_STORAGE_DELETE_FAILED");
    }
}
