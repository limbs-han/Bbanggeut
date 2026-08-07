package com.wj.server.device.domain;

import java.time.Instant;
import java.util.UUID;

public record RegistrationCodeRow(
    UUID id,
    UUID deviceId,
    Instant expiresAt,
    Instant usedAt,
    String deviceStatus
) {
}
