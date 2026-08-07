package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Device subscription policy. Payment is out of MVP scope; the subscription
 * state itself drives the retention rules.
 */
@ConfigurationProperties(prefix = "app.subscription")
public record SubscriptionProperties(int premiumRetentionDays, Duration grace) {
}
