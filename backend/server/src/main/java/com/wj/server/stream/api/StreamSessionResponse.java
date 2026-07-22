package com.wj.server.stream.api;

import java.time.Instant;
import java.util.UUID;

public record StreamSessionResponse(
    UUID sessionId,
    UUID streamId,
    UUID deviceId,
    String status,
    String playUrl,
    int heartbeatIntervalSeconds,
    Instant viewerExpiresAt,
    Instant edgeHardExpiresAt,
    String failureCode,
    Instant createdAt
) {
}
