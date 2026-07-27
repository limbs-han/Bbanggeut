package com.wj.server.iot.event;

import java.time.Instant;
import java.util.UUID;

public record DeviceEvent(
    UUID id,
    UUID deviceId,
    String type,
    Instant occurredAt,
    Double confidence,
    String localClipState,
    Integer beforeMs,
    Integer afterMs,
    Integer mergeWindowMs,
    String sourceNodeId,
    String sourceComponent,
    String sourceModelVersion
) {
}
