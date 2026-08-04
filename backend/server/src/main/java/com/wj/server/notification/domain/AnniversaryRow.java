package com.wj.server.notification.domain;

import java.util.UUID;

public record AnniversaryRow(
    UUID scheduleId,
    UUID userId,
    String title,
    String memo,
    String emoji
) {
}
