package com.wj.server.auth.domain;

import java.time.Instant;
import java.util.UUID;

public record AuthSessionRow(
    UUID id,
    UUID userId,
    String refreshTokenHash,
    Instant expiresAt,
    Instant revokedAt
) {
}
