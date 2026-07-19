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
        request.setDescription(null);
        when(mapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(mapper.findAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));

        service.update(userId, video.id(), request);

        verify(mapper).updateMetadata(video.id(), true, "새 제목", true, null, false, null);
    }

    @Test
    void updateRejectsEmptyPatch() {
        assertThatThrownBy(() -> service.update(UUID.randomUUID(), UUID.randomUUID(), new UpdateVideoRequest()))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("VALIDATION_FAILED");
    }

    @Test
    void memberCannotDeleteButResourceIsNotHidden() {
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

    private VideoRow video() {
        Instant now = Instant.parse("2026-07-17T10:00:00Z");
        return new VideoRow(
            UUID.randomUUID(), UUID.randomUUID(), "IOT_CAPTURE", "TOUCH", "event-1",
            "영상", "설명", "video/mp4", 100L, "a".repeat(64), 1000L,
            now.minusSeconds(1), now, "private/video.mp4", "READY", false, now);
    }
}
