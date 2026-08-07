package com.wj.server.device.domain;

import java.util.UUID;

public record DeviceStatusRow(
    UUID deviceId,
    String status,
    boolean recording,
    int uploadQueueDepth,
    Integer bufferSeconds,
    Integer personCount
) {
}
