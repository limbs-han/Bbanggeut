package com.wj.server.invitation.domain;

import java.time.Instant;
import java.util.UUID;

public record JoinRequestRow(
    UUID id,
    UUID deviceId,
    UUID userId,
    String email,
    String displayName,
    String status,
    Instant requestedAt
) {
}
