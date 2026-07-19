package com.wj.server.stream.domain;

import java.time.Instant;
import java.util.UUID;

public record DeviceStreamRow(
    UUID id,
    UUID deviceId,
    String status,
    Instant edgeHardExpiresAt,
    Instant stopDeadlineAt,
    String failureCode
) {
}
