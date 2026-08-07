package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.device-claim")
public record DeviceClaimProperties(int maxFailures, Duration failureWindow) {
}
