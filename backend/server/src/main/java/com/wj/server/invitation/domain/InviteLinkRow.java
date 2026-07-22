package com.wj.server.invitation.domain;

import java.time.Instant;
import java.util.UUID;

public record InviteLinkRow(
    UUID id,
    UUID deviceId,
    Instant expiresAt,
    Instant revokedAt,
    String deviceStatus
) {
}
