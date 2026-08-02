package com.wj.server.stream.api;

import java.time.Instant;
import java.util.UUID;

public record TalkbackResponse(
    UUID sessionId,
    UUID streamId,
    UUID deviceId,
    String whipUrl,
    int heartbeatIntervalSeconds,
    Instant expiresAt
) {
}
