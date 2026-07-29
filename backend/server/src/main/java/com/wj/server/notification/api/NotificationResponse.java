package com.wj.server.notification.api;

import java.time.Instant;
import java.util.UUID;

public record NotificationResponse(
    UUID id,
    String type,
    String title,
    String body,
    UUID deviceId,
    UUID resourceId,
    Instant readAt,
    Instant createdAt
) {
}
