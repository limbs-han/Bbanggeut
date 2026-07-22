package com.wj.server.provisioning.api;

import java.util.UUID;
import java.time.Instant;

public record ProvisionedDeviceResponse(
    UUID deviceId,
    String serialNumber,
    String keyId,
    String bearerToken,
    String purpose,
    Instant expiresAt,
    String mqttUsername
) {
}
