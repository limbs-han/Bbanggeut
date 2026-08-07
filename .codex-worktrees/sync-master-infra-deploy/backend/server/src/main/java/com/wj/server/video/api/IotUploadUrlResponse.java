package com.wj.server.video.api;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

public record IotUploadUrlResponse(
    UUID videoId,
    boolean alreadyCompleted,
    String uploadUrl,
    String method,
    Map<String, String> requiredHeaders,
    Instant expiresAt
) {
}
