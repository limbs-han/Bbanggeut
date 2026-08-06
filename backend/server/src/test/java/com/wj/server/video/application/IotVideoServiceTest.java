package com.wj.server.video.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.config.SubscriptionProperties;
import com.wj.server.iot.event.DeviceEventService;
import com.wj.server.notification.application.NotificationService;
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
    @Mock
    private NotificationService notificationService;
    @Mock
    private com.wj.server.device.persistence.DeviceMapper deviceMapper;
    @Mock
    private com.wj.server.audit.application.AuditService auditService;

    private IotVideoService service;

    @BeforeEach
    void setUp() {
        service = new IotVideoService(
            videoMapper, objectStorageService,
            new SubscriptionProperties(365, java.time.Duration.ofDays(30)),
            deviceEventService, notificationService, deviceMapper, auditService);
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

    /**
     * 감지를 끄면 서버가 막는다. 영상 행을 만들기 전에 막아야 한다 — 뒤에서
     * 막으면 꺼진 동안에도 UPLOADING 행이 쌓이고 sweep 워커가 그것을 치운다.
     */
    @Test
    void uploadIsRefusedWhileDetectionIsOff() {
        when(videoMapper.isClaimedDevice(DEVICE_ID)).thenReturn(true);
        when(deviceMapper.findDetectionEnabled(DEVICE_ID)).thenReturn(Optional.of(false));

        assertThatThrownBy(() -> service.createUploadUrl(DEVICE_ID, EVENT_ID, request(100)))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("DETECTION_DISABLED");

        verify(videoMapper, never()).findByDeviceEvent(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any());
        // "그날 왜 아무것도 안 찍혔나"를 나중에 설명할 수 있어야 한다.
        verify(auditService).denied(
            DEVICE_ID, null, "IOT_VIDEO_UPLOAD", "DEVICE", DEVICE_ID, "DETECTION_DISABLED");
    }

    /**
     * 409여야 한다. 기기 업로더는 403·409만 terminal로 보고 재시도하지 않는다 —
     * 429나 5xx면 재시도 큐에 쌓였다가 다시 켠 순간 밀린 것이 한꺼번에 들어온다.
     */
    @Test
    void theRefusalIsTerminalForTheDeviceUploader() {
        when(videoMapper.isClaimedDevice(DEVICE_ID)).thenReturn(true);
        when(deviceMapper.findDetectionEnabled(DEVICE_ID)).thenReturn(Optional.of(false));

        assertThatThrownBy(() -> service.createUploadUrl(DEVICE_ID, EVENT_ID, request(100)))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).status())
            .isEqualTo(org.springframework.http.HttpStatus.CONFLICT);
    }

    /** 기기 행을 못 읽으면 막지 않는다 — 스위치를 못 읽었다고 녹화를 잃지 않는다. */
    @Test
    void anUnreadableSwitchDoesNotBlockTheUpload() {
        when(videoMapper.isClaimedDevice(DEVICE_ID)).thenReturn(true);
        when(deviceMapper.findDetectionEnabled(DEVICE_ID)).thenReturn(Optional.empty());
        when(videoMapper.findByDeviceEvent(DEVICE_ID, EVENT_ID))
            .thenReturn(Optional.of(video("READY")));

        var response = service.createUploadUrl(DEVICE_ID, EVENT_ID, request(100));

        assertThat(response.alreadyCompleted()).isTrue();
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
    void completionRejectsWhenStoredObjectIsNotWhatTheDeviceUploaded() {
        // 서명 URL이 유출돼 같은 크기·같은 sha256 메타로 내용만 바뀐 경우 —
        // MinIO가 계산한 ETag가 기기가 받은 것과 달라진다.
        VideoRow video = video("UPLOADING");
        when(videoMapper.findOwnedVideo(DEVICE_ID, VIDEO_ID)).thenReturn(Optional.of(video));
        when(objectStorageService.stat(video.storageKey()))
            .thenReturn(new ObjectStorageService.StoredObject(100, CHECKSUM, "substituted-etag"));

        assertThatThrownBy(() -> service.complete(
            DEVICE_ID, EVENT_ID, new IotUploadCompleteRequest(VIDEO_ID, "\"device-etag\"")))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("UPLOAD_INTEGRITY_MISMATCH");
        verify(videoMapper, never()).markReady(DEVICE_ID, VIDEO_ID, 365);
    }

    @Test
    void completionAcceptsQuotedAndCasedEtagFromDevice() {
        VideoRow video = video("UPLOADING");
        when(videoMapper.findOwnedVideo(DEVICE_ID, VIDEO_ID))
            .thenReturn(Optional.of(video))
            .thenReturn(Optional.of(video("READY")));
        when(objectStorageService.stat(video.storageKey()))
            .thenReturn(new ObjectStorageService.StoredObject(100, CHECKSUM, "\"ABCDEF\""));
        when(videoMapper.markReady(DEVICE_ID, VIDEO_ID, 365)).thenReturn(1);

        var response = service.complete(
            DEVICE_ID, EVENT_ID, new IotUploadCompleteRequest(VIDEO_ID, "abcdef"));

        assertThat(response.id()).isEqualTo(VIDEO_ID);
    }

    @Test
    void completedLaughterVideoNotifiesDeviceMembersIdempotently() {
        VideoRow laughterVideo = new VideoRow(
            VIDEO_ID, DEVICE_ID, "IOT_CAPTURE", "LAUGHTER", EVENT_ID, "웃음 영상",
            "video/mp4", 100L, CHECKSUM, 1000L,
            Instant.parse("2026-07-17T10:00:00Z"), Instant.parse("2026-07-17T10:00:01Z"),
            "private/device/video.mp4", "READY", false,
            Instant.parse("2026-07-17T10:00:02Z"), "LAUGHTER,CLAP");
        when(videoMapper.findOwnedVideo(DEVICE_ID, VIDEO_ID))
            .thenReturn(Optional.of(laughterVideo));

        var response = service.complete(
            DEVICE_ID, EVENT_ID, new IotUploadCompleteRequest(VIDEO_ID, null));

        assertThat(response.eventTypes()).containsExactly("LAUGHTER", "CLAP");
        verify(notificationService).laughterVideoReady(
            DEVICE_ID, VIDEO_ID, laughterVideo.title());
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

    @Test
    void uploadReturnsDomainConflictWhenActiveVaultBindingIsMissing() {
        when(videoMapper.isClaimedDevice(DEVICE_ID)).thenReturn(true);
        when(videoMapper.findByDeviceEvent(DEVICE_ID, EVENT_ID))
            .thenReturn(Optional.empty(), Optional.empty());
        when(videoMapper.insertIotVideo(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.eq(DEVICE_ID),
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.eq(EVENT_ID),
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyLong(),
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyLong(),
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any()))
            .thenReturn(0);

        assertThatThrownBy(() -> service.createUploadUrl(
            DEVICE_ID, EVENT_ID, request(100)))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("DEVICE_VAULT_BINDING_MISSING");
        verify(objectStorageService, never()).createUploadUrl(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.any());
    }

    @Test
    void mixedEventTypesMustContainPrimaryTriggerType() {
        var request = new IotUploadUrlRequest(
            EVENT_ID, "LAUGHTER", "혼합 이벤트",
            Instant.parse("2026-07-17T10:00:00Z"),
            Instant.parse("2026-07-17T10:00:01Z"),
            1000, "video/mp4", 100, CHECKSUM, List.of("CLAP"));

        assertThatThrownBy(() -> service.createUploadUrl(DEVICE_ID, EVENT_ID, request))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("VALIDATION_FAILED");
    }

    @Test
    void completionRejectsVaultStateTransitionFailure() {
        VideoRow uploading = video("UPLOADING");
        when(videoMapper.findOwnedVideo(DEVICE_ID, VIDEO_ID))
            .thenReturn(Optional.of(uploading), Optional.of(uploading));
        when(objectStorageService.stat(uploading.storageKey()))
            .thenReturn(new ObjectStorageService.StoredObject(100, CHECKSUM, "etag"));
        when(videoMapper.markReady(DEVICE_ID, VIDEO_ID, 365)).thenReturn(0);

        assertThatThrownBy(() -> service.complete(
            DEVICE_ID, EVENT_ID, new IotUploadCompleteRequest(VIDEO_ID, null)))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("VIDEO_STATE_CONFLICT");
        verify(notificationService, never()).laughterVideoReady(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.any());
    }

    private IotUploadUrlRequest request(long size) {
        return new IotUploadUrlRequest(
            EVENT_ID, "TOUCH", "영상", Instant.parse("2026-07-17T10:00:00Z"),
            Instant.parse("2026-07-17T10:00:01Z"), 1000, "video/mp4", size, CHECKSUM);
    }

    private VideoRow video(String status) {
        return new VideoRow(
            VIDEO_ID, DEVICE_ID, "IOT_CAPTURE", "TOUCH", EVENT_ID, "영상",
            "video/mp4", 100L, CHECKSUM, 1000L,
            Instant.parse("2026-07-17T10:00:00Z"), Instant.parse("2026-07-17T10:00:01Z"),
            "private/device/video.mp4", status, false, Instant.parse("2026-07-17T10:00:02Z"));
    }
}
