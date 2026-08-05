package com.wj.server.schedule.domain;

import java.time.LocalDate;
import java.util.UUID;

/**
 * 금고 공유 일정 한 줄.
 *
 * <p>{@code userId}는 작성자다. 수정·삭제를 작성자와 금고 OWNER에게만 열기
 * 때문에 누가 적었는지가 계속 필요하다. {@code vaultId}가 비어 있으면 금고가
 * 없던 시절에 적은 개인 일정이다.
 */
public record ScheduleRow(
    UUID id,
    UUID userId,
    UUID vaultId,
    String authorName,
    String title,
    LocalDate scheduleDate,
    String memo,
    boolean yearly,
    String emoji
) {
}
