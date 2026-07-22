package com.wj.server.video.application;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.List;
import java.util.UUID;

import com.wj.server.video.persistence.VideoMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class RetentionSweepWorkerTest {

    @Mock
    private VideoMapper videoMapper;

    @Test
    void expiredVideosAreQueuedForDeletion() {
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        when(videoMapper.markRetentionExpiredDeleting(100)).thenReturn(List.of(first, second));

        new RetentionSweepWorker(videoMapper).sweep();

        verify(videoMapper).insertDeletionJob(first);
        verify(videoMapper).insertDeletionJob(second);
    }

    @Test
    void quietSweepDoesNothing() {
        when(videoMapper.markRetentionExpiredDeleting(100)).thenReturn(List.of());

        new RetentionSweepWorker(videoMapper).sweep();

        verify(videoMapper, never()).insertDeletionJob(any());
    }
}
