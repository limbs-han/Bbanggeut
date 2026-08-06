package com.wj.server.video.domain;

import java.time.Instant;
import java.util.UUID;

/**
 * 영상 분석의 진행 상태. 결과 자체는 워커 저장소(MinIO)에 있고 여기는 상태만이다.
 *
 * @param videoId     원본 영상 id
 * @param status      RUNNING | DONE | FAILED
 * @param stage       download·audio·yamnet·video·expression 중 지금 단계
 * @param progress    0.0~1.0
 * @param error       실패 사유. 실패가 아니면 null
 * @param requestedBy 분석을 청한 사람. 탈퇴하면 null이 된다
 * @param startedAt   시작 시각
 * @param finishedAt  끝난 시각. 진행 중이면 null
 */
public record VideoAnalysisRow(
    UUID videoId,
    String status,
    String stage,
    float progress,
    String error,
    UUID requestedBy,
    Instant startedAt,
    Instant finishedAt
) {
    public boolean running() {
        return "RUNNING".equals(status);
    }
}
