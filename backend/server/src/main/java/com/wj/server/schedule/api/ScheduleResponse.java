package com.wj.server.schedule.api;

import java.time.LocalDate;
import java.util.UUID;

import com.wj.server.schedule.domain.ScheduleRow;

/**
 * 금고 구성원이 함께 보는 일정.
 *
 * <p>{@code authorId}·{@code authorName}을 함께 주는 이유는 앱이 "내가 적은
 * 일정인가"를 보고 수정·삭제 버튼을 가려야 하기 때문이다. 서버도 같은 규칙으로
 * 거르지만, 눌러 봐야 거절되는 버튼을 띄울 이유가 없다.
 */
public record ScheduleResponse(
    UUID id,
    UUID authorId,
    String authorName,
    LocalDate date,
    String title,
    String memo,
    boolean yearly,
    String emoji
) {
    public static ScheduleResponse from(ScheduleRow row) {
        return new ScheduleResponse(
            row.id(), row.userId(), row.authorName(), row.scheduleDate(),
            row.title(), row.memo(), row.yearly(), row.emoji());
    }
}
