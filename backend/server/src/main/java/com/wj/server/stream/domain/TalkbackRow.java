package com.wj.server.stream.domain;

import java.time.Instant;
import java.util.UUID;

public record TalkbackRow(
    UUID deviceId,
    UUID sessionId,
    UUID streamId,
    UUID userId,
    Instant expiresAt
) {
}
