package com.wj.server.vault.api;

import java.time.Instant;
import java.util.UUID;

public record VaultDeviceResponse(
    UUID bindingId,
    int generation,
    UUID deviceId,
    String name,
    String model,
    String status,
    Instant lastSeenAt
) {
}
