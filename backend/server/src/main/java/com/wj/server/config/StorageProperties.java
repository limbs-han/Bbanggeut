package com.wj.server.config;

import java.time.Duration;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.storage")
public record StorageProperties(
    String endpoint,
    String publicEndpoint,
    String accessKey,
    String secretKey,
    String bucket,
    /** 편집 서버(editor-api) 부산물 버킷. 비어 있으면 편집 데이터 청소를 건너뛴다. */
    String editBucket,
    Duration uploadUrlTtl,
    Duration readUrlTtl
) {
}
