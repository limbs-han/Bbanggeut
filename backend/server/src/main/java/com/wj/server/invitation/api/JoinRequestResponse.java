package com.wj.server.invitation.api;

import java.time.Instant;
import java.util.UUID;

import com.wj.server.auth.api.UserSummary;

public record JoinRequestResponse(
    UUID id,
    UUID deviceId,
    UserSummary requester,
    String status,
    Instant requestedAt
) {
}
