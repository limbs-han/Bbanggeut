package com.wj.server.notification.domain;

public record NotificationPreferenceRow(
    boolean anniversaryAlerts,
    boolean weeklyReport,
    boolean newMemoryAlerts
) {
}
