package com.wj.server.vault.api;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

public record VaultResponse(
    UUID id,
    String name,
    String status,
    String myRole,
    int retentionDays,
    boolean subscriptionActive,
    Instant subscriptionGraceUntil,
    List<VaultDeviceResponse> devices
) {
}
