package com.wj.server.invitation.domain;

import java.time.Instant;
import java.util.UUID;

public record MembershipRequestRow(
    UUID id,
    UUID requesterId,
    String email,
    String displayName,
    Instant expiresAt,
    Instant usedAt
) {
}
