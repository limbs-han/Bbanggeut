package com.wj.server.device.domain;

import java.time.Instant;
import java.util.UUID;

public record DeviceViewRow(
    UUID id,
    String name,
    String model,
    String status,
    String myRole,
    int retentionDays,
    Instant lastSeenAt,
    String serialNumber,
    String firmwareVersion,
    Instant claimedAt
) {
}
