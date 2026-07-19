package com.wj.server.device.api;

import java.time.Instant;
import java.util.UUID;

public record DeviceStatusResponse(
    UUID deviceId,
    String status,
    boolean recording,
    int uploadQueueDepth,
    Integer bufferSeconds,
    Instant checkedAt
) {
}
