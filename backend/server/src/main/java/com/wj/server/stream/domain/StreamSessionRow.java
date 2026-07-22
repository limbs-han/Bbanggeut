package com.wj.server.stream.domain;

import java.time.Instant;
import java.util.UUID;

public record StreamSessionRow(
    UUID id,
    UUID streamId,
    UUID deviceId,
    UUID userId,
    String status,
    Instant lastActivityAt,
    Instant viewerExpiresAt,
    Instant edgeHardExpiresAt,
    String failureCode,
    Instant createdAt
) {
}
