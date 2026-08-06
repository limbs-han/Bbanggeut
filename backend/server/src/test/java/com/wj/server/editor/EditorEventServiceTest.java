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
import com.wj.server.video.application.VideoAnalysisService;
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
    @Mock
    private VideoAnalysisService analyses;

    private static final UUID VIDEO_ID = UUID.randomUUID();
    private static final UUID USER_ID = UUID.randomUUID();

    private Jwt token(String issuer, String typ) {
        return new Jwt(
            "token-value", Instant.now(), Instant.now().plusSeconds(60),
            Map.of("alg", "HS256"),
            Map.of("iss", issuer, "typ", typ, "sub", "editor-api"));
    }

    private EditorEventService service() {
        return new EditorEventService(decoder, notifications, comics, analyses);
    }

    @Test
    void analysisReadyEventNotifiesRequester() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        service().handle(
            "Bearer valid",
            new EditorEventRequest("ANALYSIS_READY", VIDEO_ID, USER_ID, null, null, null, null));

        verify(notifications).editAnalysisReady(USER_ID, VIDEO_ID);
        verify(analyses).markDone(VIDEO_ID, USER_ID);
    }

    /**
     * 진행 보고는 상태만 남긴다. 단계마다 알림을 만들면 영상 하나에 알림이 다섯
     * 번 뜬다.
     */
    @Test
    void analysisProgressUpdatesStateWithoutNotifying() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        service().handle(
            "Bearer valid",
            new EditorEventRequest(
                "ANALYSIS_PROGRESS", VIDEO_ID, null, null, null, "yamnet", 0.35f));

        verify(analyses).markProgress(VIDEO_ID, "yamnet", 0.35f);
        verifyNoInteractions(notifications);
    }

    @Test
    void analysisStartedRecordsWhoAskedForIt() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        service().handle(
            "Bearer valid",
            new EditorEventRequest(
                "ANALYSIS_STARTED", VIDEO_ID, USER_ID, null, null, "download", null));

        verify(analyses).markStarted(VIDEO_ID, "download", USER_ID);
        verifyNoInteractions(notifications);
    }

    /** 실패를 안 남기면 백엔드가 RUNNING을 든 채로 앱이 영원히 분석 중을 본다. */
    @Test
    void analysisFailureIsRecordedWithItsReason() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        service().handle(
            "Bearer valid",
            new EditorEventRequest(
                "ANALYSIS_FAILED", VIDEO_ID, USER_ID, null,
                "RuntimeError: 디코더가 죽었다", null, null));

        verify(analyses).markFailed(VIDEO_ID, "RuntimeError: 디코더가 죽었다", USER_ID);
    }

    /**
     * 청한 사람 없이 끝난 분석도 상태는 남아야 한다 — 알림만 건너뛴다. 안 그러면
     * 다른 가족이 연 화면이 계속 분석 중을 보여 준다.
     */
    @Test
    void analysisReadyWithoutARequesterStillRecordsTheState() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        service().handle(
            "Bearer valid",
            new EditorEventRequest(
                "ANALYSIS_READY", VIDEO_ID, null, null, null, null, null));

        verify(analyses).markDone(VIDEO_ID, null);
        verifyNoInteractions(notifications);
    }

    @Test
    void commentEventNotifiesFamily() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        service().handle(
            "Bearer valid",
            new EditorEventRequest("COMMENT_ADDED", VIDEO_ID, USER_ID, "7", "귀엽다", null, null));

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
            new EditorEventRequest("COMIC_READY", VIDEO_ID, USER_ID, null, null, null, null));

        var order = inOrder(comics, notifications);
        // 만든 사람으로 요청자를 남긴다 — 자기가 만든 만화는 자기가 지운다.
        order.verify(comics).register(VIDEO_ID, USER_ID);
        order.verify(notifications).comicReady(USER_ID, VIDEO_ID);
    }

    @Test
    void accessTokenIssuerIsRejected() {
        // 사용자 액세스 토큰(iss=wj-server)으로는 서비스 이벤트를 못 보낸다.
        when(decoder.decode("user-token")).thenReturn(token("wj-server", "editor-event"));

        assertThatThrownBy(() -> service().handle(
            "Bearer user-token",
            new EditorEventRequest("ANALYSIS_READY", VIDEO_ID, USER_ID, null, null, null, null)))
            .isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.code()).isEqualTo("AUTHENTICATION_REQUIRED"));
        verifyNoInteractions(notifications);
    }

    @Test
    void missingOrInvalidTokenIsRejected() {
        when(decoder.decode("broken")).thenThrow(new JwtException("bad"));

        assertThatThrownBy(() -> service().handle(
            null, new EditorEventRequest("ANALYSIS_READY", VIDEO_ID, USER_ID, null, null, null, null)))
            .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> service().handle(
            "Bearer broken",
            new EditorEventRequest("ANALYSIS_READY", VIDEO_ID, USER_ID, null, null, null, null)))
            .isInstanceOf(ApiException.class);
        verifyNoInteractions(notifications);
    }

    @Test
    void unknownTypeIsRejected() {
        when(decoder.decode("valid")).thenReturn(token("wj-editor", "editor-event"));

        assertThatThrownBy(() -> service().handle(
            "Bearer valid",
            new EditorEventRequest("SOMETHING_ELSE", VIDEO_ID, USER_ID, null, null, null, null)))
            .isInstanceOfSatisfying(ApiException.class,
                failure -> assertThat(failure.code()).isEqualTo("VALIDATION_FAILED"));
    }
}
