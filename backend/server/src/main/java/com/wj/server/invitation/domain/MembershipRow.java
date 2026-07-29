package com.wj.server.invitation.domain;

import java.time.Instant;
import java.util.UUID;
import org.apache.ibatis.annotations.AutomapConstructor;

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
    @AutomapConstructor
    public MembershipRow {
    }

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
