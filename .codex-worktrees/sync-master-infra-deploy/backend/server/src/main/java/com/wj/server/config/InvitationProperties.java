package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.invitation")
public record InvitationProperties(Duration ttl) {
    public InvitationProperties {
        if (ttl == null || ttl.isNegative() || ttl.isZero()) {
            throw new IllegalArgumentException("app.invitation.ttl must be positive");
        }
    }
}
