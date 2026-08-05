package com.wj.server.video.domain;

import java.time.Instant;
import java.util.UUID;

public record VideoCommentRow(
    UUID id,
    UUID authorId,
    String authorName,
    String body,
    Instant createdAt
) {
}
