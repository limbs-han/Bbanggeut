package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.comic")
public record ComicProperties(
    String workerBaseUrl,
    Duration workerTimeout,
    Duration rateWindow,
    int rateLimit
) {
    public ComicProperties {
        if (workerBaseUrl == null || workerBaseUrl.isBlank()) {
            throw new IllegalArgumentException("app.comic.worker-base-url must be set");
        }
        if (workerTimeout == null || rateWindow == null) {
            throw new IllegalArgumentException("app.comic timeouts must be set");
        }
        if (rateLimit < 1) {
            throw new IllegalArgumentException("app.comic.rate-limit must be positive");
        }
    }
}
