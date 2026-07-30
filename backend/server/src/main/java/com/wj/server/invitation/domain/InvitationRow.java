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
    String role,
    String status,
    Instant expiresAt,
    Instant createdAt,
    UUID vaultId,
    String vaultName
) {
    public InvitationRow(
        UUID id,
        UUID deviceId,
        String deviceName,
        UUID inviterId,
        String inviterEmail,
        String inviterDisplayName,
        String inviteeEmail,
        String role,
        String status,
        Instant expiresAt,
        Instant createdAt
    ) {
        this(
            id, deviceId, deviceName, inviterId, inviterEmail,
            inviterDisplayName, inviteeEmail, role, status, expiresAt,
            createdAt, null, null);
    }
}
