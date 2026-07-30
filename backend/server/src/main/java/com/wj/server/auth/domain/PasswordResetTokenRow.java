package com.wj.server.auth.domain;

import java.time.Instant;
import java.util.UUID;

public record PasswordResetTokenRow(
    UUID id,
    UUID userId,
    Instant expiresAt,
    Instant usedAt
) {
}
