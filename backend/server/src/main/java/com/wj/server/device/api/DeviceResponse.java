package com.wj.server.device.api;

import java.time.Instant;
import java.util.UUID;

/**
 * @param detectionEnabled 감지·저장 스위치. false면 서버가 이 기기의 영상
 *                         업로드를 거절한다. 기기는 여전히 찍고 올리려 시도한다 —
 *                         펌웨어를 바꾸지 않는 서버 측 차단이다.
 */
public record DeviceResponse(
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
    boolean detectionEnabled
) {
}
