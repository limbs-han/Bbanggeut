package com.wj.server.video.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.config.SubscriptionProperties;
import com.wj.server.iot.event.DeviceEventService;
import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.api.IotUploadCompleteRequest;
import com.wj.server.video.api.IotUploadUrlRequest;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class IotVideoServiceTest {
    private static final UUID DEVICE_ID = UUID.randomUUID();
    private static final UUID VIDEO_ID = UUID.randomUUID();
    private static final String EVENT_ID = UUID.randomUUID().toString();
    private static final String CHECKSUM = "a".repeat(64);

    @Mock
    private VideoMapper videoMapper;
    @Mock
    private ObjectStorageService objectStorageService;
    @Mock
    private DeviceEventService deviceEventService;

    private IotVideoService service;

    @BeforeEach
    void setUp() {
        service = new IotVideoService(
            videoMapper, objectStorageService,
            new SubscriptionProperties(365, java.time.Duration.ofDays(30)),
            deviceEventService);
    }

    @Test
    void completedUploadIsReturnedIdempotentlyWithoutNewUrl() {
        when(videoMapper.isClaimedDevice(DEVICE_ID)).thenReturn(true);
        when(videoMapper.findByDeviceEvent(DEVICE_ID, EVENT_ID))
            .thenReturn(Optional.of(video("READY")));

        var response = service.createUploadUrl(DEVICE_ID, EVENT_ID, request(100));

        assertThat(response.alreadyCompleted()).isTrue();
        assertThat(response.uploadUrl()).isNull();
        verify(objectStorageService, never()).createUploadUrl(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.any());
    }

    @Test
    void completionRejectsStorageChecksumMismatch() {
        VideoRow video = video("UPLOADING");
        when(videoMapper.findOwnedVideo(DEVICE_ID, VIDEO_ID)).thenReturn(Optional.of(video));
        when(objectStorageService.stat(video.storageKey()))
            .thenReturn(new ObjectStorageService.StoredObject(100, "b".repeat(64), "etag"));

        assertThatThrownBy(() -> service.complete(
            DEVICE_ID, EVENT_ID, new IotUploadCompleteRequest(VIDEO_ID, null)))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("UPLOAD_INTEGRITY_MISMATCH");
        verify(videoMapper, never()).markReady(DEVICE_ID, VIDEO_ID, 365);
    }

    @Test
    void uploadLargerThanFiveHundredMibReturns413() {
        assertThatThrownBy(() -> service.createUploadUrl(
            DEVICE_ID, EVENT_ID, request(524_288_001L)))
            .isInstanceOf(ApiException.class)
            .satisfies(exception -> {
                ApiException apiException = (ApiException) exception;
                assertThat(apiException.status().value()).isEqualTo(413);
                assertThat(apiException.code()).isEqualTo("VIDEO_TOO_LARGE");
            });
    }

    @Test
    void failedUploadCanRetryWithSameEventId() {
        when(videoMapper.isClaimedDevice(DEVICE_ID)).thenReturn(true);
        when(videoMapper.findByDeviceEvent(DEVICE_ID, EVENT_ID))
            .thenReturn(Optional.of(video("FAILED")), Optional.of(video("UPLOADING")));
        when(videoMapper.retryFailedUpload(DEVICE_ID, VIDEO_ID)).thenReturn(1);
        when(objectStorageService.createUploadUrl(
            "private/device/video.mp4", "video/mp4", CHECKSUM))
            .thenReturn(new ObjectStorageService.PresignedUpload(
                "https://storage.example/upload", java.util.Map.of("Content-Type", "video/mp4"),
                Instant.parse("2026-07-17T10:15:00Z")));

        var response = service.createUploadUrl(DEVICE_ID, EVENT_ID, request(100));

        assertThat(response.alreadyCompleted()).isFalse();
        assertThat(response.uploadUrl()).isEqualTo("https://storage.example/upload");
        verify(videoMapper).retryFailedUpload(DEVICE_ID, VIDEO_ID);
        verify(deviceEventService).linkUpload(
            DEVICE_ID, UUID.fromString(EVENT_ID), "TOUCH",
            Instant.parse("2026-07-17T10:00:00Z"), VIDEO_ID, "UPLOADING");
    }

    private IotUploadUrlRequest request(long size) {
        return new IotUploadUrlRequest(
            EVENT_ID, "TOUCH", "영상", Instant.parse("2026-07-17T10:00:00Z"),
            Instant.parse("2026-07-17T10:00:01Z"), 1000, "video/mp4", size, CHECKSUM);
    }

    private VideoRow video(String status) {
        return new VideoRow(
            VIDEO_ID, DEVICE_ID, "IOT_CAPTURE", "TOUCH", EVENT_ID, "영상", null,
            "video/mp4", 100L, CHECKSUM, 1000L,
            Instant.parse("2026-07-17T10:00:00Z"), Instant.parse("2026-07-17T10:00:01Z"),
            "private/device/video.mp4", status, false, Instant.parse("2026-07-17T10:00:02Z"));
    }
}
