package com.wj.server.vault.api;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

public record VaultEventStatsResponse(
    UUID vaultId,
    LocalDate from,
    LocalDate to,
    String timeZone,
    long detectedCount,
    long uploadedVideoCount,
    List<NamedCount> byType,
    List<DeviceCount> byDevice,
    List<DailyCount> dailyCounts
) {
    public record NamedCount(String name, long count) {
    }

    public record DeviceCount(UUID deviceId, String name, long count) {
    }

    public record DailyCount(LocalDate date, long count) {
    }
}
