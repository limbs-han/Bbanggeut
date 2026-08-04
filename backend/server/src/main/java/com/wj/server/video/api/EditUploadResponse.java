package com.wj.server.video.api;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

public record EditUploadResponse(
    UUID editVideoId,
    String uploadUrl,
    String uploadMethod,
    Map<String, String> requiredHeaders,
    Instant expiresAt
) {
}
