package com.wj.server.subscription.api;

import java.time.Instant;
import java.util.UUID;

public record SubscriptionResponse(
    UUID deviceId,
    boolean active,
    Instant graceUntil,
    int premiumRetentionDays
) {
}
