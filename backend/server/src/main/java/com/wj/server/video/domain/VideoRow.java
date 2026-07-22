package com.wj.server.video.domain;

import java.time.Instant;
import java.util.UUID;

public record VideoRow(
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
    String storageKey,
    String status,
    boolean favorite,
    Instant createdAt
) {
}
