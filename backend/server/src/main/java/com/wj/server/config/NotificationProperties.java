package com.wj.server.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.notification")
public record NotificationProperties(
    boolean emailEnabled,
    String from,
    int maxAttempts
) {
    public NotificationProperties {
        if (from == null || from.isBlank()) {
            throw new IllegalArgumentException("app.notification.from must not be blank");
        }
        if (maxAttempts < 1) {
            throw new IllegalArgumentException("app.notification.max-attempts must be positive");
        }
    }
}
