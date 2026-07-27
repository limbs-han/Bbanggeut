package com.wj.server.video.application;

import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.video.api.UpdateVideoRequest;
import com.wj.server.video.api.VideoResponse;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class VideoCommandService {
    private final VideoMapper videoMapper;
    private final AuditService auditService;

    public VideoCommandService(VideoMapper videoMapper, AuditService auditService) {
        this.videoMapper = videoMapper;
        this.auditService = auditService;
    }

    @Transactional
    public VideoResponse update(UUID userId, UUID videoId, UpdateVideoRequest request) {
        validate(request);
        VideoRow video = videoMapper.lockAccessibleVideo(userId, videoId).orElseThrow(this::notFound);
        String role = videoMapper.findActiveRole(userId, videoId).orElseThrow(this::notFound);
        if (!"OWNER".equals(role) && !"EDITOR".equals(role)) {
            auditService.denied(
                video.deviceId(), userId, "VIDEO_UPDATE", "VIDEO", videoId, "FORBIDDEN_ROLE");
            throw new ApiException(
                HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE",
                "OWNER 또는 EDITOR 권한이 필요합니다.");
        }
        videoMapper.updateMetadata(
            videoId, request.titlePresent(), normalizedTitle(request),
            request.descriptionPresent(), request.description(),
            request.favoritePresent(), request.favorite());
        VideoResponse response = toResponse(
            videoMapper.findAccessibleVideo(userId, videoId).orElseThrow(this::notFound));
        auditService.success(video.deviceId(), userId, "VIDEO_UPDATE", "VIDEO", videoId);
        return response;
    }

    @Transactional
    public void delete(UUID userId, UUID videoId) {
        VideoRow video = videoMapper.lockAccessibleVideo(userId, videoId).orElseThrow(this::notFound);
        String role = videoMapper.findActiveRole(userId, videoId).orElseThrow(this::notFound);
        if (!"OWNER".equals(role)) {
            auditService.denied(
                video.deviceId(), userId, "VIDEO_DELETE", "VIDEO", videoId, "FORBIDDEN_ROLE");
            throw new ApiException(HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE", "OWNER만 영상을 삭제할 수 있습니다.");
        }
        if (videoMapper.markDeleting(video.id(), userId) != 1) {
            throw notFound();
        }
        videoMapper.insertDeletionJob(video.id());
        auditService.success(video.deviceId(), userId, "VIDEO_DELETE", "VIDEO", videoId);
    }

    private void validate(UpdateVideoRequest request) {
        if (!request.titlePresent() && !request.descriptionPresent() && !request.favoritePresent()) {
            throw validation("수정할 필드를 하나 이상 입력해야 합니다.");
        }
        if (request.titlePresent()) {
            if (request.title() == null || request.title().trim().isEmpty() || request.title().trim().length() > 120) {
                throw validation("title은 공백이 아닌 1자 이상 120자 이하여야 합니다.");
            }
        }
        if (request.descriptionPresent() && request.description() != null && request.description().length() > 500) {
            throw validation("description은 500자 이하여야 합니다.");
        }
        if (request.favoritePresent() && request.favorite() == null) {
            throw validation("isFavorite은 null일 수 없습니다.");
        }
    }

    private String normalizedTitle(UpdateVideoRequest request) {
        return request.titlePresent() ? request.title().trim() : null;
    }

    private VideoResponse toResponse(VideoRow video) {
        return new VideoResponse(
            video.id(), video.deviceId(), video.sourceType(), video.triggerType(), video.sourceEventId(),
            video.title(), video.description(), video.contentType(), video.sizeBytes(), video.checksumSha256(),
            video.durationMs(), video.capturedStartAt(), video.capturedEndAt(), video.status(), video.favorite(),
            null, video.createdAt());
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }
}
