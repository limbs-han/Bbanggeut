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
    String contentType,
    Long sizeBytes,
    String checksumSha256,
    Long durationMs,
    Instant capturedStartAt,
    Instant capturedEndAt,
    String storageKey,
    String status,
    boolean favorite,
    Instant createdAt,
    String eventTypesCsv
) {
    public VideoRow(
        UUID id,
        UUID deviceId,
        String sourceType,
        String triggerType,
        String sourceEventId,
        String title,
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
        this(
            id, deviceId, sourceType, triggerType, sourceEventId, title,
            contentType, sizeBytes, checksumSha256, durationMs,
            capturedStartAt, capturedEndAt, storageKey, status, favorite,
            createdAt, triggerType);
    }
}
