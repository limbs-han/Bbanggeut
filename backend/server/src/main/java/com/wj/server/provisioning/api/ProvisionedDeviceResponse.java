package com.wj.server.provisioning.api;

import java.util.UUID;

public record ProvisionedDeviceResponse(
    UUID deviceId,
    String serialNumber,
    String keyId,
    String bearerToken
) {
}
