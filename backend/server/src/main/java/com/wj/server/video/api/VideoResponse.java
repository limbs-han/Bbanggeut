package com.wj.server.video.api;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

public record VideoResponse(
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
    String status,
    boolean isFavorite,
    String thumbnailUrl,
    Instant createdAt,
    List<String> eventTypes
) {
    public VideoResponse(
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
        String status,
        boolean isFavorite,
        String thumbnailUrl,
        Instant createdAt
    ) {
        this(
            id, deviceId, sourceType, triggerType, sourceEventId, title,
            contentType, sizeBytes, checksumSha256, durationMs,
            capturedStartAt, capturedEndAt, status, isFavorite, thumbnailUrl,
            createdAt, List.of(triggerType));
    }
}
