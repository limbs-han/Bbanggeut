package com.wj.server.invitation.api;

import java.time.Instant;

public record MembershipRequestPreviewResponse(
    String email,
    String displayName,
    Instant expiresAt
) {
}
