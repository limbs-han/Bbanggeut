package com.wj.server.subscription.domain;

import java.time.Instant;

public record SubscriptionRow(boolean subscriptionActive, Instant subscriptionGraceUntil) {
}
