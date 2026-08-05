package com.wj.server.video.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.video.api.UpdateVideoRequest;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class VideoCommandServiceTest {
    @Mock
    private VideoMapper mapper;
    @Mock
    private AuditService auditService;
    private VideoCommandService service;

    @BeforeEach
    void setUp() {
        service = new VideoCommandService(mapper, auditService);
    }

    @Test
    void updateSupportsExplicitDescriptionClearAndNormalizesTitle() {
        UUID userId = UUID.randomUUID();
        VideoRow video = video();
        UpdateVideoRequest request = new UpdateVideoRequest();
        request.setTitle("  새 제목  ");
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findActiveRole(userId, video.id())).thenReturn(Optional.of("OWNER"));
        when(mapper.findAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));

        service.update(userId, video.id(), request);

        verify(mapper).updateMetadata(video.id(), true, "새 제목", false, null);
    }

    @Test
    void memberCannotRenameCapturedVideo() {
        // 기기가 담아 온 원본은 가족 공동의 기록이라 이름은 OWNER가 정한다.
        UUID userId = UUID.randomUUID();
        VideoRow video = video();
        UpdateVideoRequest request = new UpdateVideoRequest();
        request.setTitle("내 마음대로 바꾼 제목");
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findActiveRole(userId, video.id())).thenReturn(Optional.of("MEMBER"));

        assertThatThrownBy(() -> service.update(userId, video.id(), request))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> {
                ApiException apiException = (ApiException) exception;
                assertThat(apiException.status().value()).isEqualTo(403);
                assertThat(apiException.code()).isEqualTo("FORBIDDEN_ROLE");
            });
    }

    @Test
    void memberCanRenameEditOutput() {
        // 편집본은 구성원이 직접 만든 결과물이다.
        UUID userId = UUID.randomUUID();
        VideoRow video = editOutput();
        UpdateVideoRequest request = new UpdateVideoRequest();
        request.setTitle("내가 만든 편집본");
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findActiveRole(userId, video.id())).thenReturn(Optional.of("MEMBER"));
        when(mapper.findAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));

        service.update(userId, video.id(), request);

        verify(mapper).updateMetadata(video.id(), true, "내가 만든 편집본", false, null);
    }

    @Test
    void memberCanStillFavoriteCapturedVideo() {
        // 제목을 못 바꾸는 것과 보기 표시를 못 하는 것은 다른 일이다.
        UUID userId = UUID.randomUUID();
        VideoRow video = video();
        UpdateVideoRequest request = new UpdateVideoRequest();
        request.setFavorite(true);
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findActiveRole(userId, video.id())).thenReturn(Optional.of("MEMBER"));
        when(mapper.findAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));

        service.update(userId, video.id(), request);

        verify(mapper).updateMetadata(video.id(), false, null, true, true);
    }

    @Test
    void updateRejectsEmptyPatch() {
        assertThatThrownBy(() -> service.update(UUID.randomUUID(), UUID.randomUUID(), new UpdateVideoRequest()))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("VALIDATION_FAILED");
    }

    @Test
    void viewerCannotUpdateVideoMetadata() {
        UUID userId = UUID.randomUUID();
        VideoRow video = video();
        UpdateVideoRequest request = new UpdateVideoRequest();
        request.setTitle("새 제목");
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findActiveRole(userId, video.id())).thenReturn(Optional.of("LEGACY_VIEWER"));

        assertThatThrownBy(() -> service.update(userId, video.id(), request))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> {
                ApiException apiException = (ApiException) exception;
                assertThat(apiException.status().value()).isEqualTo(403);
                assertThat(apiException.code()).isEqualTo("FORBIDDEN_ROLE");
            });
    }

    @Test
    void editorCannotDeleteButResourceIsNotHidden() {
        UUID userId = UUID.randomUUID();
        VideoRow video = video();
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findActiveRole(userId, video.id())).thenReturn(Optional.of("MEMBER"));

        assertThatThrownBy(() -> service.delete(userId, video.id()))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> {
                ApiException apiException = (ApiException) exception;
                assertThat(apiException.status().value()).isEqualTo(403);
                assertThat(apiException.code()).isEqualTo("FORBIDDEN_ROLE");
            });
    }

    @Test
    void ownerDeleteMarksInaccessibleAndEnqueuesObjectDeletion() {
        UUID userId = UUID.randomUUID();
        VideoRow video = video();
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findActiveRole(userId, video.id())).thenReturn(Optional.of("OWNER"));
        when(mapper.markDeleting(video.id(), userId)).thenReturn(1);

        service.delete(userId, video.id());

        verify(mapper).insertDeletionJob(video.id());
    }

    @Test
    void memberCanDeleteOwnEditOutput() {
        // 자기가 만든 편집본은 스스로 치울 수 있어야 한다.
        UUID userId = UUID.randomUUID();
        VideoRow video = editOutput();
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findActiveRole(userId, video.id())).thenReturn(Optional.of("MEMBER"));
        when(mapper.findCreatorId(video.id())).thenReturn(Optional.of(userId));
        when(mapper.markDeleting(video.id(), userId)).thenReturn(1);

        service.delete(userId, video.id());

        verify(mapper).insertDeletionJob(video.id());
    }

    @Test
    void memberCannotDeleteSomeoneElsesEditOutput() {
        UUID userId = UUID.randomUUID();
        VideoRow video = editOutput();
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findActiveRole(userId, video.id())).thenReturn(Optional.of("MEMBER"));
        when(mapper.findCreatorId(video.id())).thenReturn(Optional.of(UUID.randomUUID()));

        assertThatThrownBy(() -> service.delete(userId, video.id()))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> {
                ApiException apiException = (ApiException) exception;
                assertThat(apiException.status().value()).isEqualTo(403);
                assertThat(apiException.code()).isEqualTo("FORBIDDEN_ROLE");
            });
    }

    @Test
    void ownerCanDeleteAnyEditOutput() {
        UUID userId = UUID.randomUUID();
        VideoRow video = editOutput();
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findActiveRole(userId, video.id())).thenReturn(Optional.of("OWNER"));
        when(mapper.markDeleting(video.id(), userId)).thenReturn(1);

        service.delete(userId, video.id());

        verify(mapper).insertDeletionJob(video.id());
    }

    private VideoRow video() {
        return video("IOT_CAPTURE");
    }

    private VideoRow editOutput() {
        return video("EDIT_OUTPUT");
    }

    private VideoRow video(String sourceType) {
        Instant now = Instant.parse("2026-07-17T10:00:00Z");
        return new VideoRow(
            UUID.randomUUID(), UUID.randomUUID(), sourceType, "TOUCH", "event-1",
            "영상", "video/mp4", 100L, "a".repeat(64), 1000L,
            now.minusSeconds(1), now, "private/video.mp4", "READY", false, now);
    }
}
