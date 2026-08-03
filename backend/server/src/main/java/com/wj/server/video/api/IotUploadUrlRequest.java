package com.wj.server.video.api;

import java.time.Instant;
import java.util.List;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

public record IotUploadUrlRequest(
    @NotBlank @Size(max = 100) String sourceEventId,
    @NotBlank @Pattern(regexp = "LAUGHTER|CLAP|WAKE_WORD|TOUCH|MANUAL") String triggerType,
    @NotBlank @Size(max = 120) String title,
    @NotNull Instant capturedStartAt,
    @NotNull Instant capturedEndAt,
    @Min(1) long durationMs,
    @NotBlank @Pattern(regexp = "video/mp4") String contentType,
    @Min(1) long sizeBytes,
    @NotBlank @Pattern(regexp = "[0-9a-f]{64}") String checksumSha256,
    @Size(min = 1, max = 3)
    List<@NotBlank @Pattern(regexp = "LAUGHTER|CLAP|WAKE_WORD|TOUCH|MANUAL") String> eventTypes
) {
    public IotUploadUrlRequest(
        String sourceEventId,
        String triggerType,
        String title,
        Instant capturedStartAt,
        Instant capturedEndAt,
        long durationMs,
        String contentType,
        long sizeBytes,
        String checksumSha256
    ) {
        this(
            sourceEventId, triggerType, title, capturedStartAt, capturedEndAt,
            durationMs, contentType, sizeBytes, checksumSha256, null);
    }
}
