package com.wj.server.editor;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.notification.application.NotificationService;
import com.wj.server.video.application.ComicFeedService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtException;

@ExtendWith(MockitoExtension.class)
class EditorEventServiceTest {
    @Mock
    private JwtDecoder decoder;
    @Mock
    private NotificationService notifications;
    @Mock
    private ComicFeedService comics;

    private static final UUID VIDEO_ID = UUID.randomUUID();
    private static final UUID USER_ID = UUID.randomUUID();

    private Jwt token(String issuer, String typ) {
        return new Jwt(
            "token-value", Instant.now(), Instant.now().plusSeconds(60),
            Map.of("alg", "HS256"),
            Map.of("iss", issuer, "typ", typ, "sub", "editor-api"));
    }

    private EditorEventService service() {
        return new EditorEventService(decoder, notifications, comics);
    }

    @Test
    void analysisReadyEventNotifiesRequester() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        service().handle(
            "Bearer valid",
            new EditorEventRequest("ANALYSIS_READY", VIDEO_ID, USER_ID, null, null));

        verify(notifications).editAnalysisReady(USER_ID, VIDEO_ID);
    }

    @Test
    void commentEventNotifiesFamily() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        service().handle(
            "Bearer valid",
            new EditorEventRequest("COMMENT_ADDED", VIDEO_ID, USER_ID, "7", "귀엽다"));

        verify(notifications).editCommentAdded(USER_ID, VIDEO_ID, "7", "귀엽다");
    }

    /**
     * 만화가 완성되면 알림보다 **만화 행이 먼저** 필요하다 — 제목·좋아요·댓글이
     * 그 행을 참조하고, 피드도 그 행을 읽는다. 알림만 보내면 만화가 어디에도
     * 나타나지 않는다.
     */
    @Test
    void comicReadyEventRegistersTheComicAndNotifies() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        service().handle(
            "Bearer valid",
            new EditorEventRequest("COMIC_READY", VIDEO_ID, USER_ID, null, null));

        var order = inOrder(comics, notifications);
        order.verify(comics).register(VIDEO_ID);
        order.verify(notifications).comicReady(USER_ID, VIDEO_ID);
    }

    @Test
    void accessTokenIssuerIsRejected() {
        // 사용자 액세스 토큰(iss=wj-server)으로는 서비스 이벤트를 못 보낸다.
        when(decoder.decode("user-token")).thenReturn(token("wj-server", "editor-event"));

        assertThatThrownBy(() -> service().handle(
            "Bearer user-token",
            new EditorEventRequest("ANALYSIS_READY", VIDEO_ID, USER_ID, null, null)))
            .isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.code()).isEqualTo("AUTHENTICATION_REQUIRED"));
        verifyNoInteractions(notifications);
    }

    @Test
    void missingOrInvalidTokenIsRejected() {
        when(decoder.decode("broken")).thenThrow(new JwtException("bad"));

        assertThatThrownBy(() -> service().handle(
            null, new EditorEventRequest("ANALYSIS_READY", VIDEO_ID, USER_ID, null, null)))
            .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service().handle(
            "Bearer broken",
            new EditorEventRequest("ANALYSIS_READY", VIDEO_ID, USER_ID, null, null)))
            .isInstanceOf(ApiException.class);
        verifyNoInteractions(notifications);
    }

    @Test
    void unknownTypeIsRejected() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        assertThatThrownBy(() -> service().handle(
            "Bearer valid",
            new EditorEventRequest("SOMETHING_ELSE", VIDEO_ID, USER_ID, null, null)))
            .isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.code()).isEqualTo("VALIDATION_FAILED"));
    }
}
