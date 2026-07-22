package com.wj.server.video.api;

import java.time.Instant;
import java.util.UUID;

public record VideoResponse(
    UUID id,
    UUID deviceId,
    String sourceType,
    String triggerType,
    String sourceEventId,
    String title,
    String description,
    String contentType,
    Long sizeBytes,
    String checksumSha256,
    Long durationMs,
    Instant capturedStartAt,
    Instant capturedEndAt,
    String status,
    boolean isFavorite,
    String thumbnailUrl,
    Instant createdAt
) {
}
