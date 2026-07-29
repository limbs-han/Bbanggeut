package com.wj.server.vault.domain;

import java.time.Instant;
import java.util.UUID;

public record VaultViewRow(
    UUID id,
    String name,
    String status,
    String myRole,
    int retentionDays,
    boolean subscriptionActive,
    Instant subscriptionGraceUntil,
    UUID bindingId,
    int bindingGeneration,
    UUID deviceId,
    String deviceName,
    String deviceModel,
    String deviceStatus,
    Instant deviceLastSeenAt
) {
}
