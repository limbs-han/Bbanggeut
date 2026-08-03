package com.wj.server.video.application;

import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.time.Instant;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.api.SignedUrlResponse;
import com.wj.server.video.api.VideoPageResponse;
import com.wj.server.video.api.VideoResponse;
import com.wj.server.video.domain.VideoEventTypes;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class VideoQueryService {
    private static final Set<String> TRIGGER_TYPES = Set.of(
        "LAUGHTER", "CLAP", "WAKE_WORD", "TOUCH", "MANUAL", "USER_UPLOAD", "EDIT");

    private final VideoMapper videoMapper;
    private final VideoCursorCodec cursorCodec;
    private final ObjectStorageService objectStorageService;
    private final AuditService auditService;

    public VideoQueryService(
        VideoMapper videoMapper,
        VideoCursorCodec cursorCodec,
        ObjectStorageService objectStorageService,
        AuditService auditService
    ) {
        this.videoMapper = videoMapper;
        this.cursorCodec = cursorCodec;
        this.objectStorageService = objectStorageService;
        this.auditService = auditService;
    }

    @Transactional(readOnly = true)
    public VideoPageResponse list(
        UUID userId,
        UUID deviceId,
        String triggerType,
        Instant from,
        Instant to,
        String cursor,
        int size
    ) {
        if (size < 1 || size > 100) {
            throw validation("size는 1 이상 100 이하여야 합니다.");
        }
        if (triggerType != null && !TRIGGER_TYPES.contains(triggerType)) {
            throw validation("지원하지 않는 triggerType입니다.");
        }
        if (from != null && to != null && !from.isBefore(to)) {
            throw validation("from은 to보다 이전이어야 합니다.");
        }
        if (!videoMapper.hasActiveMembership(userId, deviceId)) {
            throw notFound();
        }

        VideoCursorCodec.Cursor decoded = cursorCodec.decode(cursor);
        List<VideoRow> rows = videoMapper.findAccessibleVideos(
            userId, deviceId, triggerType, from, to, decoded.createdAt(), decoded.id(), size + 1);
        boolean hasNext = rows.size() > size;
        List<VideoRow> pageRows = hasNext ? rows.subList(0, size) : rows;
        String nextCursor = hasNext
            ? cursorCodec.encode(pageRows.get(pageRows.size() - 1).createdAt(), pageRows.get(pageRows.size() - 1).id())
            : null;
        VideoPageResponse response = new VideoPageResponse(
            pageRows.stream().map(this::toResponse).toList(), nextCursor, hasNext);
        auditService.success(deviceId, userId, "VIDEO_LIST", "DEVICE", deviceId);
        return response;
    }

    @Transactional(readOnly = true)
    public VideoPageResponse listByVault(
        UUID userId,
        UUID vaultId,
        String triggerType,
        Instant from,
        Instant to,
        String cursor,
        int size
    ) {
        if (size < 1 || size > 100) {
            throw validation("size는 1 이상 100 이하여야 합니다.");
        }
        if (triggerType != null && !TRIGGER_TYPES.contains(triggerType)) {
            throw validation("지원하지 않는 triggerType입니다.");
        }
        if (from != null && to != null && !from.isBefore(to)) {
            throw validation("from은 to보다 이전이어야 합니다.");
        }
        if (!videoMapper.hasVaultMembership(userId, vaultId)) {
            throw notFound();
        }

        VideoCursorCodec.Cursor decoded = cursorCodec.decode(cursor);
        List<VideoRow> rows = videoMapper.findAccessibleVideosByVault(
            userId, vaultId, triggerType, from, to,
            decoded.createdAt(), decoded.id(), size + 1);
        boolean hasNext = rows.size() > size;
        List<VideoRow> pageRows = hasNext ? rows.subList(0, size) : rows;
        String nextCursor = hasNext
            ? cursorCodec.encode(
                pageRows.get(pageRows.size() - 1).createdAt(),
                pageRows.get(pageRows.size() - 1).id())
            : null;
        return new VideoPageResponse(
            pageRows.stream().map(this::toResponse).toList(), nextCursor, hasNext);
    }

    @Transactional(readOnly = true)
    public VideoResponse get(UUID userId, UUID videoId) {
        VideoRow video = accessibleVideo(userId, videoId);
        auditService.success(video.deviceId(), userId, "VIDEO_VIEW", "VIDEO", videoId);
        return toResponse(video);
    }

    @Transactional(readOnly = true)
    public SignedUrlResponse createReadUrl(UUID userId, UUID videoId, boolean download) {
        VideoRow video = accessibleVideo(userId, videoId);
        if (!"READY".equals(video.status())) {
            auditService.denied(
                video.deviceId(), userId, download ? "VIDEO_DOWNLOAD" : "VIDEO_PLAY",
                "VIDEO", videoId, "VIDEO_NOT_READY");
            throw new ApiException(
                HttpStatus.CONFLICT, "VIDEO_NOT_READY", "영상이 아직 재생 가능한 상태가 아닙니다.");
        }
        var signed = objectStorageService.createReadUrl(video.storageKey(), download);
        auditService.success(
            video.deviceId(), userId, download ? "VIDEO_DOWNLOAD" : "VIDEO_PLAY", "VIDEO", videoId);
        return new SignedUrlResponse(signed.url(), signed.expiresAt());
    }

    private VideoRow accessibleVideo(UUID userId, UUID videoId) {
        return videoMapper.findAccessibleVideo(userId, videoId).orElseThrow(this::notFound);
    }

    private VideoResponse toResponse(VideoRow video) {
        return new VideoResponse(
            video.id(), video.deviceId(), video.sourceType(), video.triggerType(),
            video.sourceEventId(), video.title(), video.description(), video.contentType(), video.sizeBytes(),
            video.checksumSha256(), video.durationMs(), video.capturedStartAt(),
            video.capturedEndAt(), video.status(), video.favorite(), null, video.createdAt(),
            VideoEventTypes.fromCsv(video.eventTypesCsv(), video.triggerType()));
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }
}
