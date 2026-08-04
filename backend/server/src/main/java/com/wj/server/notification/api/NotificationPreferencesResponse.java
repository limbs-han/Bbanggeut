package com.wj.server.notification.api;

public record NotificationPreferencesResponse(
    boolean anniversaryAlerts,
    boolean weeklyReport,
    boolean newMemoryAlerts
) {
}
