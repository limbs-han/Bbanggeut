package com.wj.server.invitation.api;

import java.time.Instant;
import java.util.UUID;

import com.wj.server.auth.api.UserSummary;

public record DeviceMemberResponse(
    UUID id,
    UUID deviceId,
    UserSummary user,
    String role,
    String status,
    Instant joinedAt
) {
}
