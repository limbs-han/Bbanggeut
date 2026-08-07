package com.wj.server.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.demo")
public record DemoProperties(boolean enabled, String liveHlsUrl) {
}
