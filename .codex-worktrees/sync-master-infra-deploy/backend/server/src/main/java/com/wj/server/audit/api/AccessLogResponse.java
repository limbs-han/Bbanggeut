package com.wj.server.audit.api;

import java.time.Instant;
import java.util.UUID;

public record AccessLogResponse(
    long id,
    UUID deviceId,
    UUID actorUserId,
    UUID actorDeviceId,
    String action,
    String targetType,
    UUID targetId,
    String outcome,
    String reasonCode,
    Instant createdAt
) {
}
