package com.wj.server.schedule.domain;

import java.time.LocalDate;
import java.util.UUID;

public record ScheduleRow(
    UUID id,
    UUID userId,
    String title,
    LocalDate scheduleDate,
    String memo,
    boolean yearly,
    String emoji
) {
}
