package com.wj.server.video.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.SubscriptionProperties;
import com.wj.server.device.persistence.DeviceMapper;
import com.wj.server.iot.event.DeviceEventService;
import com.wj.server.notification.application.NotificationService;
import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.api.IotUploadCompleteRequest;
import com.wj.server.video.api.IotUploadUrlRequest;
import com.wj.server.video.api.IotUploadUrlResponse;
import com.wj.server.video.api.VideoResponse;
import com.wj.server.video.domain.VideoEventTypes;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class IotVideoService {
    /**
     * 기기 이벤트 영상의 최대 크기. nginx의 /william-james-videos 본문 한도와
     * 같은 기준이어야 한다 — 한쪽만 크면 초과 본문이 MinIO 디스크에 도달한
     * 뒤에야 거절되어 그때까지 용량을 점유한다.
     */
    static final long MAX_UPLOAD_BYTES = 524_288_000L;

    private final VideoMapper videoMapper;
    private final ObjectStorageService objectStorageService;
    private final SubscriptionProperties subscriptionProperties;
    private final DeviceEventService deviceEventService;
    private final NotificationService notificationService;
    private final DeviceMapper deviceMapper;
    private final AuditService auditService;
    private final VideoThumbnailService thumbnails;

    public IotVideoService(
        VideoMapper videoMapper,
        ObjectStorageService objectStorageService,
        SubscriptionProperties subscriptionProperties,
        DeviceEventService deviceEventService,
        NotificationService notificationService,
        DeviceMapper deviceMapper,
        AuditService auditService,
        VideoThumbnailService thumbnails
    ) {
        this.thumbnails = thumbnails;
        this.videoMapper = videoMapper;
        this.objectStorageService = objectStorageService;
        this.subscriptionProperties = subscriptionProperties;
        this.deviceEventService = deviceEventService;
        this.notificationService = notificationService;
        this.deviceMapper = deviceMapper;
        this.auditService = auditService;
    }

    /**
     * 감지가 꺼진 기기의 업로드를 막는다. 영상 행을 만들기 **전에** 본다 —
     * 뒤에서 막으면 꺼진 동안에도 UPLOADING 행이 쌓이고, 그것을 청소하는
     * sweep 워커가 매번 돌아야 한다.
     *
     * <p><b>왜 409인가</b>: 기기의 업로더는 403·409를 terminal로 보고 재시도하지
     * 않는다({@code TERMINAL_HTTP_STATUSES}). 429나 5xx로 돌려주면 재시도 큐에
     * 쌓였다가 감지를 다시 켠 순간 밀린 것이 한꺼번에 들어온다 — 끄고 있던
     * 동안의 영상이 뒤늦게 전부 저장되면 끈 의미가 없다.
     *
     * <p>이것은 <b>서버 측 차단</b>이다. 기기는 여전히 찍고 올리려 시도한다.
     * 기기까지 멈추게 하려면 MQTT 명령과 펌웨어가 필요하고, 그것은 기기 팀과
     * 맞춰야 한다.
     */
    private void requireDetectionEnabled(UUID deviceId) {
        if (deviceMapper.findDetectionEnabled(deviceId).orElse(true)) {
            return;
        }
        // 남긴다. "그날 왜 아무것도 안 찍혔나"를 나중에 설명할 수 있어야 한다.
        // 행위자는 사람이 아니라 기기라 actorUserId가 없다.
        auditService.denied(
            deviceId, null, "IOT_VIDEO_UPLOAD", "DEVICE", deviceId, "DETECTION_DISABLED");
        throw new ApiException(
            HttpStatus.CONFLICT, "DETECTION_DISABLED",
            "이 카메라는 지금 감지가 꺼져 있습니다.");
    }

    @Transactional
    public IotUploadUrlResponse createUploadUrl(
        UUID deviceId,
        String idempotencyKey,
        IotUploadUrlRequest request
    ) {
        validateIdempotencyKey(idempotencyKey, request.sourceEventId());
        List<String> eventTypes = validatedEventTypes(request);
        UUID eventId = parseEventId(request.sourceEventId());
        if (request.sizeBytes() > MAX_UPLOAD_BYTES) {
            throw new ApiException(
                HttpStatus.PAYLOAD_TOO_LARGE, "VIDEO_TOO_LARGE", "영상은 500 MiB 이하여야 합니다.");
        }
        if (!request.capturedEndAt().isAfter(request.capturedStartAt())) {
            throw validation("capturedEndAt은 capturedStartAt보다 뒤여야 합니다.");
        }
        if (!videoMapper.isClaimedDevice(deviceId)) {
            throw new ApiException(HttpStatus.CONFLICT, "DEVICE_NOT_CLAIMED", "등록이 완료된 기기만 영상을 업로드할 수 있습니다.");
        }
        requireDetectionEnabled(deviceId);

        VideoRow video = videoMapper.findByDeviceEvent(deviceId, request.sourceEventId())
            .orElseGet(() -> createVideo(deviceId, request, eventTypes));
        verifySameUpload(video, request, eventTypes);
        if ("FAILED".equals(video.status())) {
            if (videoMapper.retryFailedUpload(deviceId, video.id()) != 1) {
                throw new ApiException(
                    HttpStatus.CONFLICT, "VIDEO_STATE_CONFLICT",
                    "현재 상태에서는 영상을 다시 업로드할 수 없습니다.");
            }
            video = videoMapper.findByDeviceEvent(deviceId, request.sourceEventId())
                .orElseThrow(() -> new IllegalStateException("Retried video disappeared"));
        }
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
            notifyVideoArrived(video);
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
        // 위의 sha256은 기기가 스스로 붙인 메타데이터라(MinIO는 본문을 검산하지
        // 않는다) 서명된 URL이 유출됐을 때 같은 크기·같은 메타로 내용만 바꿔치는
        // 것을 막지 못한다. ETag는 MinIO가 실제 바이트로 계산한 값이므로,
        // 기기가 PUT 응답에서 받은 ETag와 대조하면 그 치환을 잡아낸다.
        if (!etagMatches(storedObject.etag(), request.objectETag())) {
            throw new ApiException(
                HttpStatus.CONFLICT,
                "UPLOAD_INTEGRITY_MISMATCH",
                "업로드된 객체가 기기가 올린 것과 다릅니다.");
        }

        int updated = videoMapper.markReady(
            deviceId, video.id(), subscriptionProperties.premiumRetentionDays());
        VideoRow completed = videoMapper.findOwnedVideo(deviceId, video.id())
            .orElseThrow(() -> new IllegalStateException("Completed video disappeared"));
        if (updated != 1 && !"READY".equals(completed.status())) {
            throw new ApiException(
                HttpStatus.CONFLICT,
                "VIDEO_STATE_CONFLICT",
                "활성 추억 금고 연결을 확인할 수 없어 업로드를 완료하지 못했습니다.");
        }
        deviceEventService.linkUpload(
            deviceId, parseEventId(video.sourceEventId()), video.triggerType(),
            video.capturedStartAt(), video.id(), "READY");
        notifyVideoArrived(completed);
        // 목록에 쓸 미리보기를 뒤에서 만들게 맡긴다. 실패해도 업로드는 이미
        // 끝난 것이고, 그림이 없으면 앱이 예전처럼 기기에서 뽑는다.
        thumbnails.requestAsync(completed);
        return toResponse(completed);
    }

    /**
     * 기기가 스스로 잡아 담은 영상이 도착했다고 알린다.
     *
     * <p><b>왜 웃음만 알리지 않는가</b>: 예전에는 이벤트 목록에 LAUGHTER가
     * 있을 때만 알렸다. 그래서 박수(CLAP)로 잡힌 영상은 저장은 되는데 알림도
     * 알림함의 행도 만들어지지 않았고, 사용자에게는 "영상이 도착했는데 아무
     * 말이 없다"로 보였다 — 실서버에서 CLAP 영상 세 건이 연달아 그렇게
     * 지나갔다. 감지로 담긴 영상이면 알리고, 무엇 때문에 담겼는지는 제목이
     * 말해 준다. 사람이 직접 올린 영상·편집본은 여전히 알리지 않는다(올린
     * 사람은 이미 알고, 가족에게는 별도 통로가 있다).
     */
    private void notifyVideoArrived(VideoRow video) {
        List<String> eventTypes = VideoEventTypes.fromCsv(
            video.eventTypesCsv(), video.triggerType());
        if (!VideoEventTypes.isDetection(eventTypes)) {
            return;
        }
        notificationService.videoArrived(
            video.deviceId(), video.id(),
            VideoEventTypes.arrivalHeadline(eventTypes), video.title());
    }

    private VideoRow createVideo(
        UUID deviceId,
        IotUploadUrlRequest request,
        List<String> eventTypes
    ) {
        UUID videoId = UUID.randomUUID();
        String storageKey = "private/" + deviceId + "/events/" + videoId + ".mp4";
        int inserted = videoMapper.insertIotVideo(
            videoId, deviceId, request.triggerType(), VideoEventTypes.toCsv(eventTypes),
            request.sourceEventId(), storedTitle(eventTypes, request.title()),
            storageKey, request.contentType(), request.sizeBytes(), request.checksumSha256(),
            request.durationMs(), request.capturedStartAt(), request.capturedEndAt());
        return videoMapper.findByDeviceEvent(deviceId, request.sourceEventId())
            .orElseThrow(() -> {
                if (inserted == 0) {
                    return new ApiException(
                        HttpStatus.CONFLICT,
                        "DEVICE_VAULT_BINDING_MISSING",
                        "기기에 연결된 활성 추억 금고가 없습니다. 기기를 다시 등록해 주세요.");
                }
                return new IllegalStateException("Video insert did not produce a row");
            });
    }

    /**
     * 감지 영상의 제목은 서버가 정한다({@link VideoEventTypes#arrivalTitle}).
     * 기기가 보낸 제목은 사람이 올린 영상에서만 쓴다.
     */
    private static String storedTitle(List<String> eventTypes, String requested) {
        String canonical = VideoEventTypes.arrivalTitle(eventTypes);
        return canonical != null ? canonical : requested.trim();
    }

    /**
     * 같은 이벤트 ID로 다른 영상을 올리려는 것인지 본다.
     *
     * <p><b>제목은 보지 않는다.</b> 감지 영상의 제목은 이제 서버가 정하므로
     * 기기가 보낸 문자열과 저장된 값이 다른 것이 정상이다. 예전 스크립트가
     * 올려 둔 행을 재시도할 때도 마찬가지다 — 제목까지 견주면 그 재시도가
     * 전부 409가 된다. 같은 영상인지는 체크섬·크기·길이·촬영 구간·유형이
     * 이미 판정하고, 제목은 거기에 아무것도 보태지 않는다.
     */
    private void verifySameUpload(
        VideoRow video,
        IotUploadUrlRequest request,
        List<String> eventTypes
    ) {
        if (!video.triggerType().equals(request.triggerType())
            || !video.eventTypesCsv().equals(VideoEventTypes.toCsv(eventTypes))
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

    private List<String> validatedEventTypes(IotUploadUrlRequest request) {
        try {
            return VideoEventTypes.normalize(request.triggerType(), request.eventTypes());
        } catch (IllegalArgumentException exception) {
            throw validation(exception.getMessage());
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

    /**
     * MinIO가 계산한 ETag와 기기가 보고한 ETag를 견준다. 따옴표·대소문자는
     * 구현마다 달라 정규화한다.
     *
     * <p>기기가 ETag를 보내지 않은 옛 에이전트는 통과시킨다 — 이 검사는
     * 유출된 서명 URL로 내용을 바꿔치는 것을 막는 것이고, 그 공격자는
     * /complete를 부르는 주체가 아니다(기기 자격증명이 없다). 보고를 생략한
     * 기기까지 막으면 얻는 것 없이 업로드만 끊긴다.
     */
    private boolean etagMatches(String storedEtag, String reportedEtag) {
        if (reportedEtag == null || reportedEtag.isBlank()) {
            return true;
        }
        if (storedEtag == null || storedEtag.isBlank()) {
            return false;
        }
        return normalizeEtag(storedEtag).equals(normalizeEtag(reportedEtag));
    }

    private String normalizeEtag(String value) {
        return value.strip().replace("\"", "").toLowerCase(java.util.Locale.ROOT);
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }

    private VideoResponse toResponse(VideoRow video) {
        return new VideoResponse(
            video.id(), video.deviceId(), video.sourceType(), video.triggerType(),
            video.sourceEventId(), video.title(), video.contentType(), video.sizeBytes(),
            video.checksumSha256(), video.durationMs(), video.capturedStartAt(),
            video.capturedEndAt(), video.status(), video.favorite(), null, video.createdAt(),
            VideoEventTypes.fromCsv(video.eventTypesCsv(), video.triggerType()));
    }
}
