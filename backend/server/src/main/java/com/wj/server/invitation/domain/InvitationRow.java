package com.wj.server.invitation.domain;

import java.time.Instant;
import java.util.UUID;

public record InvitationRow(
    UUID id,
    UUID deviceId,
    String deviceName,
    UUID inviterId,
    String inviterEmail,
    String inviterDisplayName,
    String inviteeEmail,
    String status,
    Instant expiresAt,
    Instant createdAt
) {
}
