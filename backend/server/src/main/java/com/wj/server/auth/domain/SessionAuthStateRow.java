package com.wj.server.auth.domain;

import java.util.UUID;

/**
 * Server-side state an access token is checked against on every request:
 * the session must still be live and the token version must still match.
 */
public record SessionAuthStateRow(
    UUID userId,
    int tokenVersion,
    String status
) {
}
