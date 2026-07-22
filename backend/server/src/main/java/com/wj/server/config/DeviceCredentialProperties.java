package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.device-credential")
public record DeviceCredentialProperties(
    Duration bootstrapTtl,
    Duration operatingTtl
) {
    public DeviceCredentialProperties {
        if (bootstrapTtl == null || bootstrapTtl.isNegative() || bootstrapTtl.isZero()) {
            throw new IllegalArgumentException("bootstrapTtl must be positive");
        }
        if (operatingTtl == null || operatingTtl.isNegative() || operatingTtl.isZero()) {
            throw new IllegalArgumentException("operatingTtl must be positive");
        }
    }
}
