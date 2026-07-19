package com.wj.server.video.application;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.domain.VideoEditRow;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class VideoEditWorkerTest {
    @Mock private VideoEditJobRepository jobs;
    @Mock private ObjectStorageService storage;
    @Mock private FfmpegProcessor ffmpeg;

    @Test
    void uploadsProcessedOutputAndCompletesJob() throws Exception {
        VideoEditRow job = job();
        when(jobs.claimNext()).thenReturn(Optional.of(job));
        doAnswer(invocation -> {
            Path output = invocation.getArgument(1);
            Files.write(output, new byte[] {1, 2, 3});
            return null;
        }).when(ffmpeg).trim(any(), any(), eq(1_000L), eq(4_000L));

        new VideoEditWorker(jobs, storage, ffmpeg).processNext();

        verify(storage).download(eq(job.sourceStorageKey()), any());
        verify(storage).upload(
            org.mockito.ArgumentMatchers.startsWith("private/" + job.deviceId() + "/edits/"),
            any(), eq("video/mp4"), org.mockito.ArgumentMatchers.matches("^[0-9a-f]{64}$"));
        verify(jobs).complete(
            eq(job), any(UUID.class),
            org.mockito.ArgumentMatchers.startsWith("private/" + job.deviceId() + "/edits/"),
            eq(3L), org.mockito.ArgumentMatchers.matches("^[0-9a-f]{64}$"), any(), any());
    }

    @Test
    void ffmpegFailureMarksJobFailed() {
        VideoEditRow job = job();
        when(jobs.claimNext()).thenReturn(Optional.of(job));
        doThrow(new FfmpegProcessor.ProcessingException("FFMPEG_FAILED"))
            .when(ffmpeg).trim(any(), any(), any(Long.class), any(Long.class));

        new VideoEditWorker(jobs, storage, ffmpeg).processNext();

        verify(jobs).fail(job.id(), "FFMPEG_FAILED");
    }

    private VideoEditRow job() {
        Instant start = Instant.parse("2026-07-17T10:00:00Z");
        return new VideoEditRow(
            UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(), null, UUID.randomUUID(),
            1_000, 4_000, "Highlight", "PROCESSING", null, Instant.now(), null,
            "private/source.mp4", "video/mp4", start);
    }
}
