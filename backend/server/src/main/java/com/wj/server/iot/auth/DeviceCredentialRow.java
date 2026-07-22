package com.wj.server.iot.auth;

import java.time.Instant;
import java.util.UUID;

public record DeviceCredentialRow(
    UUID deviceId,
    String keyId,
    String secretHash,
    String status,
    Instant expiresAt,
    String deviceStatus,
    String purpose
) {
}
