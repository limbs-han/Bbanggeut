package com.wj.server.video.api;

import java.time.Instant;

import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;

/**
 * 편집 완성본 업로드 예약. 원본 영상에서 금고·기기·보관 기준을 물려받으므로
 * 여기서는 완성본 고유의 값만 받는다.
 */
public record CreateEditUploadRequest(
    @Size(max = 120) String title,
    @Positive Long durationMs,
    Instant capturedStartAt,
    Instant capturedEndAt
) {
}
