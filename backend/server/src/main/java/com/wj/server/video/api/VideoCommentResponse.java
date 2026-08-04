package com.wj.server.video.api;

import java.time.Instant;
import java.util.UUID;

public record VideoCommentResponse(
    UUID id,
    UUID authorId,
    String authorName,
    String body,
    Instant createdAt
) {
}
