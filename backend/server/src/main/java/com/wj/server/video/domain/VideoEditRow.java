package com.wj.server.video.domain;

import java.time.Instant;
import java.util.UUID;

public record VideoEditRow(
    UUID id,
    UUID deviceId,
    UUID sourceVideoId,
    UUID resultVideoId,
    UUID requestedBy,
    long startMs,
    long endMs,
    String title,
    String status,
    String errorCode,
    Instant requestedAt,
    Instant completedAt,
    String sourceStorageKey,
    String sourceContentType,
    Instant sourceCapturedStartAt
) {
}
