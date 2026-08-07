package com.wj.server.video.api;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

public record VideoStatsResponse(
    UUID deviceId,
    LocalDate from,
    LocalDate to,
    String timeZone,
    long totalCount,
    List<NamedCount> byTriggerType,
    List<DailyCount> dailyCounts,
    NamedCount peakWeekday,
    NamedCount peakHour
) {
    public record NamedCount(String name, long count) {
    }

    public record DailyCount(LocalDate date, long count) {
    }
}
