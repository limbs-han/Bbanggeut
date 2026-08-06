package com.wj.server.device.domain;

import java.time.Instant;
import java.util.UUID;

public record DeviceViewRow(
    UUID id,
    String name,
    String model,
    String status,
    String myRole,
    int retentionDays,
    Instant lastSeenAt,
    String serialNumber,
    String firmwareVersion,
    Instant claimedAt,
    /** 감지·저장 스위치. false면 서버가 이 기기의 영상 업로드를 거절한다. */
    boolean detectionEnabled
) {
}
