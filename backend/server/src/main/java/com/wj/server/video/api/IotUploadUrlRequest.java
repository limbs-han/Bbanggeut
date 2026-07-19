package com.wj.server.video.api;

import java.time.Instant;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

public record IotUploadUrlRequest(
    @NotBlank @Size(max = 100) String sourceEventId,
    @NotBlank @Pattern(regexp = "LAUGHTER|WAKE_WORD|TOUCH|MANUAL") String triggerType,
    @NotBlank @Size(max = 120) String title,
    @NotNull Instant capturedStartAt,
    @NotNull Instant capturedEndAt,
    @Min(1) long durationMs,
    @NotBlank @Pattern(regexp = "video/mp4") String contentType,
    @Min(1) long sizeBytes,
    @NotBlank @Pattern(regexp = "[0-9a-f]{64}") String checksumSha256
) {
}
