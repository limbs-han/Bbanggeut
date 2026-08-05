package com.wj.server.laughdraw.domain;

import java.time.Instant;
import java.util.UUID;

/**
 * 뽑기 후보로 고른 웃음 영상 한 건.
 *
 * <p>기존 {@code VideoRow}를 쓰지 않는 이유는 뽑기 화면이 보관 만료 시각
 * ({@code retention_until})을 함께 보여 주기 때문이다. 공용 레코드에 필드를 더하면
 * 목록·상세·통계까지 다시 매핑해야 해서 뽑기 전용 행을 따로 둔다.
 */
public record LaughMemoryRow(
    UUID id,
    UUID deviceId,
    UUID vaultId,
    String sourceType,
    String triggerType,
    String title,
    String description,
    String contentType,
    Long sizeBytes,
    Long durationMs,
    Instant capturedStartAt,
    Instant capturedEndAt,
    String status,
    boolean favorite,
    Instant retentionUntil,
    Instant createdAt,
    String eventTypesCsv
) {
}
