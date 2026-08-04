package com.wj.server.notification.api;

import jakarta.validation.constraints.NotNull;

public record UpdateNotificationPreferencesRequest(
    @NotNull Boolean anniversaryAlerts,
    @NotNull Boolean weeklyReport,
    @NotNull Boolean newMemoryAlerts
) {
}
