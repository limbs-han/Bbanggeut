package com.wj.server.video.application;

import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.video.api.CreateVideoEditRequest;
import com.wj.server.video.api.VideoEditResponse;
import com.wj.server.video.domain.VideoEditRow;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoEditMapper;
import com.wj.server.video.persistence.VideoMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class VideoEditService {
    private final VideoMapper videoMapper;
    private final VideoEditMapper editMapper;
    private final AuditService auditService;

    public VideoEditService(VideoMapper videoMapper, VideoEditMapper editMapper, AuditService auditService) {
        this.videoMapper = videoMapper;
        this.editMapper = editMapper;
        this.auditService = auditService;
    }

    @Transactional
    public VideoEditResponse create(UUID userId, UUID videoId, CreateVideoEditRequest request) {
        if (request.endMs() <= request.startMs()) {
            throw validation("endMs는 startMs보다 커야 합니다.");
        }
        VideoRow video = videoMapper.lockAccessibleVideo(userId, videoId).orElseThrow(this::notFound);
        if (!"READY".equals(video.status())) {
            throw conflict("VIDEO_NOT_READY", "READY 영상만 편집할 수 있습니다.");
        }
        if (video.durationMs() == null) {
            throw conflict("VIDEO_DURATION_UNKNOWN", "영상 길이를 확인할 수 없습니다.");
        }
        if (request.endMs() > video.durationMs()) {
            throw validation("편집 범위가 영상 길이를 초과합니다.");
        }

        UUID editId = UUID.randomUUID();
        editMapper.insert(
            editId, video.deviceId(), videoId, userId,
            request.startMs(), request.endMs(), request.title().trim());
        VideoEditResponse response = editMapper.findAccessible(userId, editId)
            .map(this::toResponse)
            .orElseThrow(this::notFound);
        auditService.success(video.deviceId(), userId, "VIDEO_EDIT", "VIDEO_EDIT", editId);
        return response;
    }

    @Transactional(readOnly = true)
    public VideoEditResponse get(UUID userId, UUID editId) {
        return editMapper.findAccessible(userId, editId).map(this::toResponse).orElseThrow(this::notFound);
    }

    private VideoEditResponse toResponse(VideoEditRow row) {
        return new VideoEditResponse(
            row.id(), row.deviceId(), row.sourceVideoId(), row.resultVideoId(), row.requestedBy(),
            row.startMs(), row.endMs(), row.status(), row.errorCode(), row.requestedAt(), row.completedAt());
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }

    private ApiException conflict(String code, String message) {
        return new ApiException(HttpStatus.CONFLICT, code, message);
    }
}
