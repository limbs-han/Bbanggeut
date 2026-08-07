package com.wj.server.invitation.api;

import java.time.Instant;

public record MembershipRequestLinkResponse(
    String token,
    Instant expiresAt
) {
}
