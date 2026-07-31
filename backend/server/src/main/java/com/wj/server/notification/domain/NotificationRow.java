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
}
