package com.wj.server.device.domain;

import java.util.UUID;

public record MembershipStateRow(UUID id, UUID userId, String role, String status) {
}
