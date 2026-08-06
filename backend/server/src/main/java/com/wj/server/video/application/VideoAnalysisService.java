package com.wj.server.video.application;

import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.video.api.VideoAnalysisResponse;
import com.wj.server.video.persistence.VideoAnalysisMapper;
import com.wj.server.video.persistence.VideoMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 영상 분석의 진행 상태.
 *
 * <p><b>왜 백엔드가 이걸 드는가</b>: 예전에는 상태가 워커 프로세스의 메모리에만
 * 있었다. 워커를 재배포하면 진행 중이던 분석이 "분석한 적 없음"으로 보였고, 앱은
 * 상태 하나를 알려고 백엔드를 지나 워커까지 물어야 했다. 상태는 작고 자주 읽는
 * 값이라 DB가 맞다 — 결과 JSON(영상당 약 700KB)은 그대로 워커 저장소에 둔다.
 */
@Service
public class VideoAnalysisService {
    private final VideoAnalysisMapper analysisMapper;
    private final VideoMapper videoMapper;

    public VideoAnalysisService(
        VideoAnalysisMapper analysisMapper, VideoMapper videoMapper
    ) {
        this.analysisMapper = analysisMapper;
        this.videoMapper = videoMapper;
    }

    /** 앱이 보는 상태. 분석한 적이 없으면 NONE이다(404가 아니다). */
    @Transactional(readOnly = true)
    public VideoAnalysisResponse status(UUID userId, UUID videoId) {
        videoMapper.findAccessibleVideo(userId, videoId).orElseThrow(
            () -> new ApiException(
                HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다."));
        return analysisMapper.find(videoId)
            .map(row -> new VideoAnalysisResponse(
                row.status(), row.stage(), row.progress(), row.error(),
                row.startedAt(), row.finishedAt()))
            .orElseGet(VideoAnalysisResponse::none);
    }

    /**
     * 워커가 분석을 시작했다. 권한을 보지 않는다 — 부르는 쪽이 서비스 토큰으로
     * 검증된 editor-api이고, 사용자 세션이 아니다.
     */
    @Transactional
    public void markStarted(UUID videoId, String stage, UUID requestedBy) {
        analysisMapper.started(videoId, stage, requestedBy);
    }

    @Transactional
    public void markProgress(UUID videoId, String stage, float progress) {
        analysisMapper.progressed(videoId, stage, clamp(progress));
    }

    @Transactional
    public void markDone(UUID videoId, UUID requestedBy) {
        analysisMapper.finished(videoId, "DONE", 1f, null, requestedBy);
    }

    /** 사유는 앱이 그대로 보여 주므로 길이를 자른다. */
    @Transactional
    public void markFailed(UUID videoId, String error, UUID requestedBy) {
        String reason = error == null || error.isBlank() ? "알 수 없는 오류" : error.strip();
        analysisMapper.finished(
            videoId, "FAILED", 0f,
            reason.length() > 500 ? reason.substring(0, 500) : reason,
            requestedBy);
    }

    private static float clamp(float value) {
        return Math.max(0f, Math.min(1f, value));
    }
}
