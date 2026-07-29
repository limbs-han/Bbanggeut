package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.stream")
public record StreamProperties(
    Duration viewerTtl,
    Duration idleTimeout,
    Duration edgeLease,
    Duration heartbeatInterval,
    String mediaBaseUrl,
    String webrtcBaseUrl,
    Duration liveTokenTtl
) {
    public StreamProperties {
        if (viewerTtl == null || idleTimeout == null || edgeLease == null
            || heartbeatInterval == null || liveTokenTtl == null) {
            throw new IllegalArgumentException("stream durations are required");
        }
        if (mediaBaseUrl == null || mediaBaseUrl.isBlank()) {
            throw new IllegalArgumentException("app.stream.media-base-url is required");
        }
        if (webrtcBaseUrl == null || webrtcBaseUrl.isBlank()) {
            throw new IllegalArgumentException("app.stream.webrtc-base-url is required");
        }
    }
}
