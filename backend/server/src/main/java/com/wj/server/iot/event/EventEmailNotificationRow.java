package com.wj.server.iot.event;

import java.time.Instant;
import java.util.UUID;

public record EventEmailNotificationRow(
    UUID id,
    UUID eventId,
    String recipientEmail,
    String deviceName,
    Instant occurredAt,
    int attempts
) {
}
