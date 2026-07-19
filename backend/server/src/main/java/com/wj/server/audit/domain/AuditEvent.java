package com.wj.server.audit.domain;

import java.util.UUID;

public record AuditEvent(
    UUID deviceId,
    UUID actorUserId,
    UUID actorDeviceId,
    String action,
    String targetType,
    UUID targetId,
    String outcome,
    String reasonCode,
    String ipAddress,
    String userAgent,
    String requestId
) {
}
