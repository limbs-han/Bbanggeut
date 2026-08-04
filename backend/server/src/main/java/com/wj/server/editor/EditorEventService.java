package com.wj.server.editor;

import com.wj.server.common.api.ApiException;
import com.wj.server.notification.application.NotificationService;
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

    public EditorEventService(JwtDecoder decoder, NotificationService notifications) {
        this.decoder = decoder;
        this.notifications = notifications;
    }

    public void handle(String authorization, EditorEventRequest request) {
        if (!verified(authorization)) {
            throw new ApiException(
                HttpStatus.UNAUTHORIZED, "AUTHENTICATION_REQUIRED", "편집 서버 토큰이 필요합니다.");
        }
        switch (request.type()) {
            case "ANALYSIS_READY" ->
                notifications.editAnalysisReady(request.userId(), request.videoId());
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
