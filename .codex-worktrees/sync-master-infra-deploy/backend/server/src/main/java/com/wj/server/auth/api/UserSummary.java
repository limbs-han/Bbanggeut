package com.wj.server.auth.api;

import java.util.UUID;

public record UserSummary(UUID id, String email, String displayName) {
}
