package com.wj.server.video.application;

import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.UUID;

import com.wj.server.video.persistence.VideoMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class UploadStateSweepWorkerTest {
    @Mock
    private VideoMapper videoMapper;

    @Test
    void staleUploadsAreFailedInBoundedBatches() {
        Instant now = Instant.parse("2026-07-26T12:00:00Z");
        Instant cutoff = now.minus(Duration.ofMinutes(30));
        when(videoMapper.markStaleUploadsFailed(cutoff, 100))
            .thenReturn(List.of(UUID.randomUUID()));

        new UploadStateSweepWorker(
            videoMapper,
            Duration.ofMinutes(30),
            Clock.fixed(now, ZoneOffset.UTC)
        ).sweep();

        verify(videoMapper).markStaleUploadsFailed(cutoff, 100);
    }
}
