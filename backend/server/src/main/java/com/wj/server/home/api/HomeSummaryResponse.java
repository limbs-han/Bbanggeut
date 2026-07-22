package com.wj.server.home.api;

import java.time.LocalDate;
import java.util.UUID;

import com.wj.server.video.api.VideoResponse;

/**
 * One-call aggregate for the home-cam dashboard: today's captured moments,
 * saved videos and memos, plus the latest highlight to preview. Backs
 * {@code GET /api/devices/{deviceId}/home-summary}.
 */
public record HomeSummaryResponse(
    UUID deviceId,
    LocalDate date,
    String timeZone,
    long captureCount,
    long savedCount,
    long memoCount,
    VideoResponse latestHighlight
) {
}
