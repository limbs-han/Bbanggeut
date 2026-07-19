package com.wj.server.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.mqtt")
public record MqttProperties(
    String brokerUrl,
    String clientId,
    String username,
    String password,
    String environment
) {
}
