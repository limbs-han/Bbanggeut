package com.wj.server.invitation.domain;

import java.time.Instant;
import java.util.UUID;

public record InvitationRow(
    UUID id,
    UUID deviceId,
    UUID inviterId,
    String inviteeEmail,
    String role,
    String status,
    Instant expiresAt,
    Instant createdAt,
    String deviceStatus
) {
}
