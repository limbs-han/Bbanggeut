package com.wj.server.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * MediaMTX 관리 API 연동. api-base-url이 비어 있으면 유령 세션 대사
 * (reconcile)가 꺼진다 — 로컬 개발·테스트는 MediaMTX 없이도 돌아야 한다.
 */
@ConfigurationProperties(prefix = "app.mediamtx")
public record MediaMtxProperties(
    String apiBaseUrl,
    String pathPrefix,
    int missesBeforeFailure
) {
    public MediaMtxProperties {
        if (pathPrefix == null || pathPrefix.isBlank()) {
            pathPrefix = "live";
        }
        if (missesBeforeFailure <= 0) {
            missesBeforeFailure = 2;
        }
    }

    public boolean enabled() {
        return apiBaseUrl != null && !apiBaseUrl.isBlank();
    }
}
