package com.wj.server.audit.domain;

import java.time.Instant;
import java.util.UUID;

public record AccessLogRow(
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
