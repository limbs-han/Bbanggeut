package com.wj.server.video.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.config.SubscriptionProperties;
import com.wj.server.notification.application.NotificationService;
import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.api.CreateEditUploadRequest;
import com.wj.server.video.api.CreateVideoCommentRequest;
import com.wj.server.video.domain.VideoCommentRow;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoCommentMapper;
import com.wj.server.video.persistence.VideoMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class EditedVideoServiceTest {
    private static final UUID USER_ID = UUID.randomUUID();
    private static final UUID SOURCE_ID = UUID.randomUUID();
    private static final UUID DEVICE_ID = UUID.randomUUID();

    @Mock
    private VideoMapper videoMapper;
    @Mock
    private VideoCommentMapper commentMapper;
    @Mock
    private ObjectStorageService objectStorageService;
    @Mock
    private NotificationService notificationService;

    private EditedVideoService service() {
        return new EditedVideoService(
            videoMapper, commentMapper, objectStorageService,
            new SubscriptionProperties(365, Duration.ofDays(30)), notificationService);
    }

    private VideoRow source() {
        return new VideoRow(
            SOURCE_ID, DEVICE_ID, "IOT_CAPTURE", "LAUGHTER", "event-1", "웃음 영상", null,
            "video/mp4", 100L, "a".repeat(64), 5000L,
            Instant.parse("2026-08-04T10:00:00Z"), Instant.parse("2026-08-04T10:00:05Z"),
            "private/device/video.mp4", "READY", false,
            Instant.parse("2026-08-04T10:00:06Z"), "LAUGHTER");
    }

    @Test
    void uploadReservationSignsUrlAndInheritsSourceCaptureTime() {
        when(videoMapper.findAccessibleVideo(USER_ID, SOURCE_ID))
            .thenReturn(Optional.of(source()));
        when(videoMapper.insertEditOutput(
            any(), eq(SOURCE_ID), eq(USER_ID), anyString(), anyString(), any(),
            eq(Instant.parse("2026-08-04T10:00:00Z")),
            eq(Instant.parse("2026-08-04T10:00:05Z")), anyInt())).thenReturn(1);
        when(objectStorageService.createEditUploadUrl(anyString(), eq("video/mp4")))
            .thenReturn(new ObjectStorageService.PresignedUpload(
                "https://minio/put", java.util.Map.of("Content-Type", "video/mp4"),
                Instant.parse("2026-08-04T10:15:00Z")));

        var response = service().createUpload(
            USER_ID, SOURCE_ID, new CreateEditUploadRequest(null, 3000L, null, null));

        assertThat(response.uploadUrl()).isEqualTo("https://minio/put");
        // 백그라운드 업로더는 헤더를 붙일 수 없다 — Content-Type만 서명해야 한다.
        assertThat(response.requiredHeaders()).containsOnlyKeys("Content-Type");
    }

    @Test
    void uploadReservationRejectsInaccessibleSource() {
        when(videoMapper.findAccessibleVideo(USER_ID, SOURCE_ID)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service().createUpload(
            USER_ID, SOURCE_ID, new CreateEditUploadRequest("제목", 1000L, null, null)))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
        verify(objectStorageService, never()).createEditUploadUrl(anyString(), anyString());
    }

    @Test
    void commentIsStoredWithTokenIdentityAndNotifiesFamily() {
        when(videoMapper.findAccessibleVideo(USER_ID, SOURCE_ID))
            .thenReturn(Optional.of(source()));

        var comment = service().addComment(
            USER_ID, SOURCE_ID, new CreateVideoCommentRequest("  귀엽다  "));

        // 작성자는 토큰의 사용자 UUID다 — 앱이 보낸 이름을 믿지 않는다.
        assertThat(comment.authorId()).isEqualTo(USER_ID);
        assertThat(comment.body()).isEqualTo("귀엽다");
        verify(commentMapper).insert(any(), eq(SOURCE_ID), eq(USER_ID), eq("귀엽다"));
        verify(notificationService).editCommentAdded(
            eq(USER_ID), eq(SOURCE_ID), anyString(), eq("귀엽다"));
    }

    @Test
    void commentListingRequiresVaultAccess() {
        when(videoMapper.findAccessibleVideo(USER_ID, SOURCE_ID)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service().listComments(USER_ID, SOURCE_ID))
            .isInstanceOf(ApiException.class)
            .hasFieldOrPropertyWithValue("code", "RESOURCE_NOT_FOUND");
    }

    @Test
    void commentListingReturnsAuthorNameFromUsersTable() {
        UUID commentId = UUID.randomUUID();
        when(videoMapper.findAccessibleVideo(USER_ID, SOURCE_ID))
            .thenReturn(Optional.of(source()));
        when(commentMapper.findForVideo(eq(SOURCE_ID), anyInt())).thenReturn(List.of(
            new VideoCommentRow(commentId, USER_ID, "박찬형", "좋아요", Instant.now())));

        var comments = service().listComments(USER_ID, SOURCE_ID);

        assertThat(comments).hasSize(1);
        assertThat(comments.get(0).authorName()).isEqualTo("박찬형");
    }
}
