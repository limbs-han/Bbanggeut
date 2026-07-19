package com.wj.server.video.api;

import java.time.Instant;
import java.util.UUID;

public record VideoEditResponse(
    UUID id,
    UUID deviceId,
    UUID sourceVideoId,
    UUID resultVideoId,
    UUID requestedBy,
    long startMs,
    long endMs,
    String status,
    String errorCode,
    Instant requestedAt,
    Instant completedAt
) {
}
