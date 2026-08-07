package com.wj.server.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.provisioning")
public record ProvisioningProperties(boolean enabled, String adminKey) {
}
