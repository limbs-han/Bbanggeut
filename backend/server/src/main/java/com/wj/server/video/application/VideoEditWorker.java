package com.wj.server.video.application;

import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.HexFormat;
import java.util.UUID;

import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.domain.VideoEditRow;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
public class VideoEditWorker {
    private static final Logger log = LoggerFactory.getLogger(VideoEditWorker.class);
    private final VideoEditJobRepository jobs;
    private final ObjectStorageService storage;
    private final FfmpegProcessor ffmpeg;

    public VideoEditWorker(
        VideoEditJobRepository jobs,
        ObjectStorageService storage,
        FfmpegProcessor ffmpeg
    ) {
        this.jobs = jobs;
        this.storage = storage;
        this.ffmpeg = ffmpeg;
    }

    @Scheduled(fixedDelayString = "${app.video-edit.worker-delay:5s}")
    public void processNext() {
        jobs.claimNext().ifPresent(this::process);
    }

    private void process(VideoEditRow job) {
        Path directory = null;
        String uploadedStorageKey = null;
        try {
            directory = Files.createTempDirectory("wj-edit-");
            Path input = directory.resolve("source.mp4");
            Path output = directory.resolve("result.mp4");
            storage.download(job.sourceStorageKey(), input);
            ffmpeg.trim(input, output, job.startMs(), job.endMs());

            long sizeBytes = Files.size(output);
            String checksum = sha256(output);
            UUID resultVideoId = UUID.randomUUID();
            uploadedStorageKey = "private/" + job.deviceId() + "/edits/" + resultVideoId + ".mp4";
            storage.upload(uploadedStorageKey, output, "video/mp4", checksum);

            Instant capturedStartAt = job.sourceCapturedStartAt() == null
                ? null : job.sourceCapturedStartAt().plusMillis(job.startMs());
            Instant capturedEndAt = capturedStartAt == null
                ? null : capturedStartAt.plusMillis(job.endMs() - job.startMs());
            jobs.complete(
                job, resultVideoId, uploadedStorageKey, sizeBytes, checksum,
                capturedStartAt, capturedEndAt);
            uploadedStorageKey = null;
        } catch (FfmpegProcessor.ProcessingException exception) {
            jobs.fail(job.id(), exception.code());
        } catch (Exception exception) {
            jobs.fail(job.id(), "VIDEO_EDIT_PROCESSING_FAILED");
            log.warn("Video edit failed: editId={}, deviceId={}", job.id(), job.deviceId());
        } finally {
            if (uploadedStorageKey != null) {
                try {
                    storage.remove(uploadedStorageKey);
                } catch (RuntimeException exception) {
                    log.warn("Orphan edit object cleanup failed: editId={}", job.id());
                }
            }
            cleanup(directory);
        }
    }

    private String sha256(Path path) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = new DigestInputStream(Files.newInputStream(path), digest)) {
            input.transferTo(java.io.OutputStream.nullOutputStream());
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    private void cleanup(Path directory) {
        if (directory == null) {
            return;
        }
        try (var paths = Files.walk(directory)) {
            paths.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                try {
                    Files.deleteIfExists(path);
                } catch (java.io.IOException ignored) {
                    // Best-effort cleanup of worker temporary files.
                }
            });
        } catch (java.io.IOException ignored) {
            // Best-effort cleanup of worker temporary files.
        }
    }
}
