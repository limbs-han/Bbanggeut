package com.wj.server.video.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class VideoQueryServiceTest {
    @Mock
    private VideoMapper videoMapper;
    @Mock
    private ObjectStorageService objectStorageService;
    @Mock
    private AuditService auditService;

    private VideoCursorCodec cursorCodec;
    private VideoQueryService service;

    @BeforeEach
    void setUp() {
        cursorCodec = new VideoCursorCodec();
        service = new VideoQueryService(videoMapper, cursorCodec, objectStorageService, auditService);
    }

    @Test
    void listReturnsOpaqueNextCursorUsingSizePlusOne() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        VideoRow first = video(deviceId, Instant.parse("2026-07-17T10:00:02Z"), "READY");
        VideoRow second = video(deviceId, Instant.parse("2026-07-17T10:00:01Z"), "READY");
        when(videoMapper.hasActiveMembership(userId, deviceId)).thenReturn(true);
        when(videoMapper.findAccessibleVideos(userId, deviceId, "TOUCH", null, null, 2))
            .thenReturn(List.of(first, second));

        var page = service.list(userId, deviceId, "TOUCH", null, 1);

        assertThat(page.items()).hasSize(1);
        assertThat(page.hasNext()).isTrue();
        assertThat(cursorCodec.decode(page.nextCursor()).id()).isEqualTo(first.id());
    }

    @Test
    void listHidesDeviceWithoutMembership() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(videoMapper.hasActiveMembership(userId, deviceId)).thenReturn(false);

        assertThatThrownBy(() -> service.list(userId, deviceId, null, null, 20))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("RESOURCE_NOT_FOUND");
        verify(videoMapper, never()).findAccessibleVideos(any(), any(), any(), any(), any(), any(Integer.class));
    }

    @Test
    void playUrlRejectsVideoThatIsNotReady() {
        UUID userId = UUID.randomUUID();
        VideoRow video = video(UUID.randomUUID(), Instant.now(), "UPLOADING");
        when(videoMapper.findAccessibleVideo(userId, video.id())).thenReturn(Optional.of(video));

        assertThatThrownBy(() -> service.createReadUrl(userId, video.id(), false))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("VIDEO_NOT_READY");
        verify(objectStorageService, never()).createReadUrl(any(), any(Boolean.class));
    }

    private VideoRow video(UUID deviceId, Instant createdAt, String status) {
        return new VideoRow(
            UUID.randomUUID(), deviceId, "IOT_CAPTURE", "TOUCH", UUID.randomUUID().toString(),
            "영상", null, "video/mp4", 100L, "a".repeat(64), 1000L,
            createdAt.minusSeconds(1), createdAt, "private/video.mp4", status, false, createdAt);
    }
}
