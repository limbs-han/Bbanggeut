package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.auth")
public record AuthProperties(
    Duration accessTokenTtl,
    Duration refreshTokenTtl,
    String jwtSecret
) {
}
