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
import com.wj.server.video.api.CreateVideoEditRequest;
import com.wj.server.video.domain.VideoEditRow;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoEditMapper;
import com.wj.server.video.persistence.VideoMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class VideoEditServiceTest {
    @Mock private VideoMapper videoMapper;
    @Mock private VideoEditMapper editMapper;
    @Mock private AuditService auditService;
    private VideoEditService service;

    @BeforeEach
    void setUp() {
        service = new VideoEditService(videoMapper, editMapper, auditService);
    }

    @Test
    void createsPendingEditInsideSourceDuration() {
        UUID userId = UUID.randomUUID();
        VideoRow video = video(10_000L, "READY");
        CreateVideoEditRequest request = new CreateVideoEditRequest(1_000, 5_000, " Highlight ");
        when(videoMapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));
        when(editMapper.findAccessible(org.mockito.ArgumentMatchers.eq(userId), org.mockito.ArgumentMatchers.any()))
            .thenAnswer(invocation -> Optional.of(edit(
                invocation.getArgument(1), video, userId, request.startMs(), request.endMs())));

        var response = service.create(userId, video.id(), request);

        assertThat(response.status()).isEqualTo("PENDING");
        verify(editMapper).insert(
            response.id(), video.deviceId(), video.id(), userId, 1_000, 5_000, "Highlight");
    }

    @Test
    void rejectsRangeBeyondSourceDuration() {
        UUID userId = UUID.randomUUID();
        VideoRow video = video(2_000L, "READY");
        when(videoMapper.lockAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));

        assertThatThrownBy(() -> service.create(
            userId, video.id(), new CreateVideoEditRequest(0, 3_000, "Too long")))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("VALIDATION_FAILED");
    }

    private VideoRow video(Long durationMs, String status) {
        Instant now = Instant.parse("2026-07-17T10:00:00Z");
        return new VideoRow(
            UUID.randomUUID(), UUID.randomUUID(), "IOT_CAPTURE", "TOUCH", "event", "Video", null,
            "video/mp4", 100L, "a".repeat(64), durationMs, now.minusSeconds(10), now,
            "private/source.mp4", status, false, now);
    }

    private VideoEditRow edit(UUID id, VideoRow video, UUID userId, long startMs, long endMs) {
        return new VideoEditRow(
            id, video.deviceId(), video.id(), null, userId, startMs, endMs, "Highlight",
            "PENDING", null, Instant.now(), null, video.storageKey(), video.contentType(),
            video.capturedStartAt());
    }
}
