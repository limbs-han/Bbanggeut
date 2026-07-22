package com.wj.server.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.demo")
public record DemoProperties(boolean enabled, String liveHlsUrl) {
    public DemoProperties {
        if (enabled && (liveHlsUrl == null || liveHlsUrl.isBlank())) {
            throw new IllegalArgumentException("app.demo.live-hls-url is required when demo mode is enabled");
        }
    }
}
