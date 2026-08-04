package com.wj.server.schedule.api;

import java.time.LocalDate;
import java.util.UUID;

import com.wj.server.schedule.domain.ScheduleRow;

public record ScheduleResponse(
    UUID id,
    String title,
    LocalDate date,
    String memo,
    boolean yearly,
    String emoji
) {
    public static ScheduleResponse from(ScheduleRow row) {
        return new ScheduleResponse(
            row.id(), row.title(), row.scheduleDate(), row.memo(), row.yearly(), row.emoji());
    }
}
