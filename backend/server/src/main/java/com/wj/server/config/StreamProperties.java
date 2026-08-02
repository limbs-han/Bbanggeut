package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.stream")
public record StreamProperties(
    Duration viewerTtl,
    Duration idleTimeout,
    Duration edgeLease,
    Duration heartbeatInterval,
    String webrtcBaseUrl,
    Duration liveTokenTtl,
    String talkbackWhipBaseUrl,
    Duration talkbackTtl
) {
    public StreamProperties {
        if (viewerTtl == null || idleTimeout == null || edgeLease == null
            || heartbeatInterval == null || liveTokenTtl == null || talkbackTtl == null) {
            throw new IllegalArgumentException("stream durations are required");
        }
        if (webrtcBaseUrl == null || webrtcBaseUrl.isBlank()) {
            throw new IllegalArgumentException("app.stream.webrtc-base-url is required");
        }
        if (talkbackWhipBaseUrl == null || talkbackWhipBaseUrl.isBlank()) {
            throw new IllegalArgumentException("app.stream.talkback-whip-base-url is required");
        }
        // 발화 권한은 heartbeat로 연장된다. 갱신 주기보다 짧으면 말하는 도중에
        // 권한이 만료되어 다른 구성원이 끼어들 수 있다.
        if (talkbackTtl.compareTo(heartbeatInterval) <= 0) {
            throw new IllegalArgumentException(
                "app.stream.talkback-ttl must be longer than heartbeat-interval");
        }
    }
}
