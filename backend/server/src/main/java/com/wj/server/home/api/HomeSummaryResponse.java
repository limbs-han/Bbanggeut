package com.wj.server.home.api;

import java.time.LocalDate;
import java.util.UUID;

import com.wj.server.video.api.VideoResponse;

/**
 * One-call aggregate for the home-cam dashboard: today's captured moments,
 * saved videos, plus the latest highlight to preview. Backs
 * {@code GET /api/devices/{deviceId}/home-summary}.
 *
 * <p>{@code memoCount}는 2026-08-05 메모 기능과 함께 뺐다. 앱은 이 값을 파싱만
 * 하고 어디에도 그리지 않았다.
 */
public record HomeSummaryResponse(
    UUID deviceId,
    LocalDate date,
    String timeZone,
    long captureCount,
    long savedCount,
    VideoResponse latestHighlight
) {
}
