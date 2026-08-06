package com.wj.server.device.api;

import java.time.Instant;
import java.util.UUID;

/**
 * @param detectionEnabled 감지·저장 스위치. 목록에 함께 실어 주면 설정 화면이
 *                         기기마다 다시 묻지 않아도 토글 상태를 그릴 수 있다.
 */
public record DeviceSummaryResponse(
    UUID id,
    String name,
    String model,
    String status,
    String myRole,
    int retentionDays,
    Instant lastSeenAt,
    boolean detectionEnabled
) {
}
