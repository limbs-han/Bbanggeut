package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.device-presence")
public record DevicePresenceProperties(Duration ttl) {
    public DevicePresenceProperties {
        if (ttl == null || ttl.isZero() || ttl.isNegative()) {
            throw new IllegalArgumentException("app.device-presence.ttl must be positive");
        }
    }
}
