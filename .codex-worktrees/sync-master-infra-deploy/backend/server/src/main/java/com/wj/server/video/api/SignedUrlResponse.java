package com.wj.server.video.api;

import java.time.Instant;

public record SignedUrlResponse(String url, Instant expiresAt) {
}
