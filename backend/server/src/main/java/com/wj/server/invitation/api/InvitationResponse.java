package com.wj.server.invitation.api;

import java.time.Instant;
import java.util.UUID;

public record InvitationResponse(
    UUID id,
    UUID deviceId,
    String inviteeEmail,
    String role,
    String status,
    Instant expiresAt,
    Instant createdAt
) {
}
