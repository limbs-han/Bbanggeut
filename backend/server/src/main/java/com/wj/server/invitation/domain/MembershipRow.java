package com.wj.server.invitation.domain;

import java.time.Instant;
import java.util.UUID;

public record MembershipRow(
    UUID id,
    UUID deviceId,
    UUID userId,
    String email,
    String displayName,
    String role,
    String status,
    Instant joinedAt,
    UUID vaultId
) {
    public MembershipRow(
        UUID id,
        UUID deviceId,
        UUID userId,
        String email,
        String displayName,
        String role,
        String status,
        Instant joinedAt
    ) {
        this(id, deviceId, userId, email, displayName, role, status, joinedAt, null);
    }
}
