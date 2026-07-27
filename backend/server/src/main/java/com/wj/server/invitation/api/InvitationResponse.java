package com.wj.server.invitation.api;

import java.time.Instant;
import java.util.UUID;

import com.wj.server.auth.api.UserSummary;

/**
 * A pending device invitation. The owner sees these per device (who is still
 * outstanding); the invited account sees these in its own inbox (which devices
 * it can join).
 */
public record InvitationResponse(
    UUID id,
    UUID deviceId,
    String deviceName,
    String inviteeEmail,
    String role,
    UserSummary inviter,
    String status,
    Instant expiresAt,
    Instant createdAt
) {
}
