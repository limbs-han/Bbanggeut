package com.wj.server.subscription.api;

import java.time.Instant;
import java.util.UUID;

/**
 * {@code deviceId} is null when the subscription was reached through the vault
 * route, which is the only route a vault with no connected device can use.
 */
public record SubscriptionResponse(
    UUID deviceId,
    UUID vaultId,
    boolean active,
    Instant graceUntil,
    int premiumRetentionDays
) {
    public SubscriptionResponse(
        UUID deviceId,
        boolean active,
        Instant graceUntil,
        int premiumRetentionDays
    ) {
        this(deviceId, null, active, graceUntil, premiumRetentionDays);
    }
}
