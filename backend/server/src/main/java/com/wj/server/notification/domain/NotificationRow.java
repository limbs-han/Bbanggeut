package com.wj.server.notification.domain;

import java.time.Instant;
import java.util.UUID;

public record NotificationRow(
    UUID id,
    String type,
    String title,
    String body,
    UUID deviceId,
    UUID vaultId,
    UUID resourceId,
    Instant readAt,
    Instant createdAt
) {
    public NotificationRow(
        UUID id,
        String type,
        String title,
        String body,
        UUID deviceId,
        UUID resourceId,
        Instant readAt,
        Instant createdAt
    ) {
        this(
            id, type, title, body, deviceId, null, resourceId, readAt,
            createdAt);
    }
}
