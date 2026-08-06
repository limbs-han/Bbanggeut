package com.wj.server.editor;

import com.wj.server.common.api.ApiException;
import com.wj.server.notification.application.NotificationService;
import com.wj.server.video.application.ComicFeedService;
import com.wj.server.video.application.VideoAnalysisService;
import org.springframework.http.HttpStatus;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtException;
import org.springframework.stereotype.Service;

/**
 * editor-api의 서비스 이벤트를 알림으로 승격한다.
 *
 * 인증은 사용자 세션이 아니라 editor-api가 백엔드와 같은 HS256 키로 서명한
 * 서비스 토큰(iss=wj-editor, typ=editor-event)이다. LiveTokenService처럼
 * 서명·만료만 보는 기본 디코더를 쓰고 발급자·용도는 여기서 직접 확인한다 —
 * 액세스 토큰(iss=wj-server)이나 라이브 토큰(iss=wj-live)으로는 통과할 수 없다.
 */
@Service
public class EditorEventService {
    private final JwtDecoder decoder;
    private final NotificationService notifications;
    private final ComicFeedService comics;
    private final VideoAnalysisService analyses;

    public EditorEventService(
        JwtDecoder decoder,
        NotificationService notifications,
        ComicFeedService comics,
        VideoAnalysisService analyses
    ) {
        this.decoder = decoder;
        this.notifications = notifications;
        this.comics = comics;
        this.analyses = analyses;
    }

    public void handle(String authorization, EditorEventRequest request) {
        if (!verified(authorization)) {
            throw new ApiException(
                HttpStatus.UNAUTHORIZED, "AUTHENTICATION_REQUIRED", "편집 서버 토큰이 필요합니다.");
        }
        switch (request.type()) {
            // 진행 보고는 알림을 만들지 않는다 — 상태만 남긴다. 단계마다 알림이
            // 나가면 영상 하나에 알림이 다섯 번 뜬다.
            case "ANALYSIS_STARTED" ->
                analyses.markStarted(
                    request.videoId(), request.stage(), request.userId());
            case "ANALYSIS_PROGRESS" ->
                analyses.markProgress(
                    request.videoId(), request.stage(),
                    request.progress() == null ? 0f : request.progress());
            case "ANALYSIS_FAILED" ->
                analyses.markFailed(
                    request.videoId(), request.body(), request.userId());
            // 상태를 먼저 남기고 알린다. 알림을 못 보내도(받는 사람이 탈퇴했다든지)
            // "분석 끝났다"는 사실은 남아야 앱이 영원히 분석 중을 보지 않는다.
            case "ANALYSIS_READY" -> {
                analyses.markDone(request.videoId(), request.userId());
                // 청한 사람이 없는 분석도 있다(상태만 남기는 경로). 알림은 받는
                // 사람이 있어야 만든다.
                if (request.userId() != null) {
                    notifications.editAnalysisReady(request.userId(), request.videoId());
                }
            }
            // 만화 행을 먼저 세운다 — 제목·좋아요·댓글이 이 행을 참조하므로,
            // 알림만 보내고 행이 없으면 피드에 나오지도 않는다. 알림을 못 보내도
            // (받는 사람이 탈퇴했다든지) 만화 자체는 남아야 한다.
            case "COMIC_READY" -> {
                comics.register(request.videoId(), request.userId());
                notifications.comicReady(request.userId(), request.videoId());
            }
            case "COMMENT_ADDED" ->
                notifications.editCommentAdded(
                    request.userId(), request.videoId(), request.commentId(), request.body());
            default -> throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED",
                "알 수 없는 편집 이벤트 타입입니다.");
        }
    }

    private boolean verified(String authorization) {
        if (authorization == null
            || !authorization.regionMatches(true, 0, "Bearer ", 0, 7)) {
            return false;
        }
        try {
            var jwt = decoder.decode(authorization.substring(7).trim());
            return "wj-editor".equals(jwt.getClaimAsString("iss"))
                && "editor-event".equals(jwt.getClaimAsString("typ"));
        } catch (JwtException exception) {
            return false;
        }
    }
}
