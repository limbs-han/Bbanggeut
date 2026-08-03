package com.wj.server.editor;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.notification.application.NotificationService;
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

    private static final UUID VIDEO_ID = UUID.randomUUID();
    private static final UUID USER_ID = UUID.randomUUID();

    private Jwt token(String issuer, String typ) {
        return new Jwt(
            "token-value", Instant.now(), Instant.now().plusSeconds(60),
            Map.of("alg", "HS256"),
            Map.of("iss", issuer, "typ", typ, "sub", "editor-api"));
    }

    private EditorEventService service() {
        return new EditorEventService(decoder, notifications);
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
