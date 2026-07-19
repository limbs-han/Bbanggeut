package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.video-edit")
public record VideoEditProperties(
    String ffmpegPath,
    Duration processTimeout,
    Duration workerDelay
) {
    public VideoEditProperties {
        if (ffmpegPath == null || ffmpegPath.isBlank()) {
            throw new IllegalArgumentException("app.video-edit.ffmpeg-path is required");
        }
        if (processTimeout == null || processTimeout.isZero() || processTimeout.isNegative()) {
            throw new IllegalArgumentException("app.video-edit.process-timeout must be positive");
        }
        if (workerDelay == null || workerDelay.isZero() || workerDelay.isNegative()) {
            throw new IllegalArgumentException("app.video-edit.worker-delay must be positive");
        }
    }
}
