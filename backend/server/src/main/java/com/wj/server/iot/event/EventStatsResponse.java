package com.wj.server.iot.event;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

public record EventStatsResponse(
    UUID deviceId,
    LocalDate from,
    LocalDate to,
    String timeZone,
    long detectedCount,
    long uploadedVideoCount,
    List<NamedCount> byType,
    List<DailyCount> dailyCounts
) {
    public record NamedCount(String name, long count) {
    }

    public record DailyCount(LocalDate date, long count) {
    }
}
