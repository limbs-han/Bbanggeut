package com.wj.server.video.api;

import java.time.Instant;

/**
 * 영상 분석 상태. 편집 화면과 만화 화면이 "분석 중"을 보여 주는 근거다.
 *
 * @param status     NONE | RUNNING | DONE | FAILED. 분석한 적이 없으면 NONE이다
 * @param stage      지금 단계(download·audio·yamnet·video·expression). 없으면 null
 * @param progress   0.0~1.0
 * @param error      실패 사유. 실패가 아니면 null
 * @param startedAt  시작 시각. 분석한 적이 없으면 null
 * @param finishedAt 끝난 시각. 진행 중이거나 분석한 적이 없으면 null
 */
public record VideoAnalysisResponse(
    String status,
    String stage,
    float progress,
    String error,
    Instant startedAt,
    Instant finishedAt
) {
    /** 분석한 적이 없는 영상. 오류가 아니라 정상적인 상태다. */
    public static VideoAnalysisResponse none() {
        return new VideoAnalysisResponse("NONE", null, 0f, null, null, null);
    }
}
