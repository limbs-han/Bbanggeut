package com.wj.server.device.domain;

import java.time.Instant;
import java.util.UUID;

public record DeviceRow(
    UUID id,
    String serialNumber,
    String productCodeHash,
    String name,
    String model,
    String firmwareVersion,
    String status,
    int retentionDays,
    Instant registrationModeExpiresAt,
    Instant productCodeRetiredAt,
    Instant claimedAt,
    UUID claimedBy,
    Instant lastSeenAt
) {
}
