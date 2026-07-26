package com.wj.server.video.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.config.SubscriptionProperties;
import com.wj.server.iot.event.DeviceEventService;
import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.api.IotUploadCompleteRequest;
import com.wj.server.video.api.IotUploadUrlRequest;
import com.wj.server.video.api.IotUploadUrlResponse;
import com.wj.server.video.api.VideoResponse;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class IotVideoService {
    private final VideoMapper videoMapper;
    private final ObjectStorageService objectStorageService;
    private final SubscriptionProperties subscriptionProperties;
    private final DeviceEventService deviceEventService;

    public IotVideoService(
        VideoMapper videoMapper,
        ObjectStorageService objectStorageService,
        SubscriptionProperties subscriptionProperties,
        DeviceEventService deviceEventService
    ) {
        this.videoMapper = videoMapper;
        this.objectStorageService = objectStorageService;
        this.subscriptionProperties = subscriptionProperties;
        this.deviceEventService = deviceEventService;
    }

    @Transactional
    public IotUploadUrlResponse createUploadUrl(
        UUID deviceId,
        String idempotencyKey,
        IotUploadUrlRequest request
    ) {
        validateIdempotencyKey(idempotencyKey, request.sourceEventId());
        UUID eventId = parseEventId(request.sourceEventId());
        if (request.sizeBytes() > 524_288_000L) {
            throw new ApiException(
                HttpStatus.PAYLOAD_TOO_LARGE, "VIDEO_TOO_LARGE", "영상은 500 MiB 이하여야 합니다.");
        }
        if (!request.capturedEndAt().isAfter(request.capturedStartAt())) {
            throw validation("capturedEndAt은 capturedStartAt보다 뒤여야 합니다.");
        }
        if (!videoMapper.isClaimedDevice(deviceId)) {
            throw new ApiException(HttpStatus.CONFLICT, "DEVICE_NOT_CLAIMED", "등록이 완료된 기기만 영상을 업로드할 수 있습니다.");
        }

        VideoRow video = videoMapper.findByDeviceEvent(deviceId, request.sourceEventId())
            .orElseGet(() -> createVideo(deviceId, request));
        verifySameUpload(video, request);
        deviceEventService.linkUpload(
            deviceId, eventId, request.triggerType(), request.capturedStartAt(),
            video.id(), video.status());

        if ("READY".equals(video.status())) {
            return new IotUploadUrlResponse(video.id(), true, null, null, null, null);
        }
        if (!"UPLOADING".equals(video.status())) {
            throw new ApiException(
                HttpStatus.CONFLICT, "VIDEO_STATE_CONFLICT", "현재 상태에서는 영상을 업로드할 수 없습니다.");
        }

        var upload = objectStorageService.createUploadUrl(
            video.storageKey(), video.contentType(), video.checksumSha256());
        return new IotUploadUrlResponse(
            video.id(), false, upload.url(), "PUT", upload.requiredHeaders(), upload.expiresAt());
    }

    @Transactional
    public VideoResponse complete(
        UUID deviceId,
        String idempotencyKey,
        IotUploadCompleteRequest request
    ) {
        VideoRow video = videoMapper.findOwnedVideo(deviceId, request.videoId())
            .orElseThrow(() -> new ApiException(
                HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다."));
        validateIdempotencyKey(idempotencyKey, video.sourceEventId());

        if ("READY".equals(video.status())) {
            deviceEventService.linkUpload(
                deviceId, parseEventId(video.sourceEventId()), video.triggerType(),
                video.capturedStartAt(), video.id(), "READY");
            return toResponse(video);
        }
        if (!"UPLOADING".equals(video.status())) {
            throw new ApiException(
                HttpStatus.CONFLICT, "VIDEO_STATE_CONFLICT", "현재 상태에서는 업로드를 완료할 수 없습니다.");
        }

        var storedObject = objectStorageService.stat(video.storageKey());
        if (storedObject.size() != video.sizeBytes()
            || storedObject.checksumSha256() == null
            || !constantTimeEquals(storedObject.checksumSha256(), video.checksumSha256())) {
            throw new ApiException(
                HttpStatus.CONFLICT,
                "UPLOAD_INTEGRITY_MISMATCH",
                "업로드된 객체의 크기 또는 체크섬이 일치하지 않습니다.");
        }

        videoMapper.markReady(deviceId, video.id(), subscriptionProperties.premiumRetentionDays());
        VideoResponse response = videoMapper.findOwnedVideo(deviceId, video.id())
            .map(this::toResponse)
            .orElseThrow(() -> new IllegalStateException("Completed video disappeared"));
        deviceEventService.linkUpload(
            deviceId, parseEventId(video.sourceEventId()), video.triggerType(),
            video.capturedStartAt(), video.id(), "READY");
        return response;
    }

    private VideoRow createVideo(UUID deviceId, IotUploadUrlRequest request) {
        UUID videoId = UUID.randomUUID();
        String storageKey = "private/" + deviceId + "/events/" + videoId + ".mp4";
        videoMapper.insertIotVideo(
            videoId, deviceId, request.triggerType(), request.sourceEventId(), request.title().trim(),
            storageKey, request.contentType(), request.sizeBytes(), request.checksumSha256(),
            request.durationMs(), request.capturedStartAt(), request.capturedEndAt());
        return videoMapper.findByDeviceEvent(deviceId, request.sourceEventId())
            .orElseThrow(() -> new IllegalStateException("Video insert did not produce a row"));
    }

    private void verifySameUpload(VideoRow video, IotUploadUrlRequest request) {
        if (!video.triggerType().equals(request.triggerType())
            || !video.title().equals(request.title().trim())
            || !video.contentType().equals(request.contentType())
            || video.sizeBytes() != request.sizeBytes()
            || video.durationMs() != request.durationMs()
            || !video.checksumSha256().equals(request.checksumSha256())
            || !video.capturedStartAt().equals(request.capturedStartAt())
            || !video.capturedEndAt().equals(request.capturedEndAt())) {
            throw new ApiException(
                HttpStatus.CONFLICT,
                "IDEMPOTENCY_CONFLICT",
                "같은 이벤트 ID에 다른 업로드 정보가 요청되었습니다.");
        }
    }

    private void validateIdempotencyKey(String idempotencyKey, String sourceEventId) {
        if (idempotencyKey == null || idempotencyKey.isBlank()
            || idempotencyKey.length() > 100 || !idempotencyKey.equals(sourceEventId)) {
            throw new ApiException(
                HttpStatus.CONFLICT,
                "IDEMPOTENCY_KEY_MISMATCH",
                "Idempotency-Key는 sourceEventId와 같아야 합니다.");
        }
    }

    private UUID parseEventId(String sourceEventId) {
        try {
            return UUID.fromString(sourceEventId);
        } catch (IllegalArgumentException exception) {
            throw validation("sourceEventId는 UUID 형식이어야 합니다.");
        }
    }

    private boolean constantTimeEquals(String actual, String expected) {
        return MessageDigest.isEqual(
            actual.getBytes(StandardCharsets.US_ASCII),
            expected.getBytes(StandardCharsets.US_ASCII));
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }

    private VideoResponse toResponse(VideoRow video) {
        return new VideoResponse(
            video.id(), video.deviceId(), video.sourceType(), video.triggerType(),
            video.sourceEventId(), video.title(), null, video.contentType(), video.sizeBytes(),
            video.checksumSha256(), video.durationMs(), video.capturedStartAt(),
            video.capturedEndAt(), video.status(), video.favorite(), null, video.createdAt());
    }
}
