package com.wj.server.iot.telemetry;

import java.time.Instant;

public record DevicePresenceSnapshot(
    Instant lastSeenAt,
    boolean recording,
    int uploadQueueDepth,
    Integer bufferSeconds,
    Integer personCount,
    String firmwareVersion
) {
}
