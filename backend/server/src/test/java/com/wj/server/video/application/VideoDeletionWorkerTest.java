package com.wj.server.video.application;

import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.verify;
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
    @Mock
    private VideoDeletionJobRepository jobs;
    @Mock
    private ObjectStorageService storage;

    @Test
    void deletesOriginalAndThumbnailThenCompletesJob() {
        VideoDeletionJob job = new VideoDeletionJob(1, UUID.randomUUID(), "video.mp4", "thumb.jpg", 1);
        when(jobs.claim(20)).thenReturn(List.of(job));

        new VideoDeletionWorker(jobs, storage).process();

        verify(storage).remove("video.mp4");
        verify(storage).remove("thumb.jpg");
        verify(jobs).complete(job);
    }

    @Test
    void storageFailureLeavesRetryableJob() {
        VideoDeletionJob job = new VideoDeletionJob(2, UUID.randomUUID(), "video.mp4", null, 2);
        when(jobs.claim(20)).thenReturn(List.of(job));
        doThrow(new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "OBJECT_STORAGE_UNAVAILABLE", "failed"))
            .when(storage).remove("video.mp4");

        new VideoDeletionWorker(jobs, storage).process();

        verify(jobs).retry(2, "OBJECT_STORAGE_DELETE_FAILED");
    }
}
