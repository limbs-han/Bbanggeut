package com.wj.server.auth.domain;

import java.util.UUID;

public record UserRow(
    UUID id,
    String email,
    String passwordHash,
    String displayName,
    String status,
    int tokenVersion
) {
}
