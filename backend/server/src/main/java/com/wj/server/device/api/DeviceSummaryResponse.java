package com.wj.server.device.api;

import java.time.Instant;
import java.util.UUID;

public record DeviceSummaryResponse(
    UUID id,
    String name,
    String model,
    String status,
    String myRole,
    int retentionDays,
    Instant lastSeenAt
) {
}
