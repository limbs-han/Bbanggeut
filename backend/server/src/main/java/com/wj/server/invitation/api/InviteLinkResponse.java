package com.wj.server.invitation.api;

import java.time.Instant;
import java.util.UUID;

/** The plaintext token appears only in this response; the server keeps a hash. */
public record InviteLinkResponse(UUID deviceId, String inviteToken, Instant expiresAt) {
}
