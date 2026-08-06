package com.wj.server.video.application;

import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.video.api.UpdateVideoRequest;
import com.wj.server.video.api.VideoResponse;
import com.wj.server.video.domain.VideoEventTypes;
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

    /**
     * 권한을 필드별로 가린다.
     *
     * 기기가 담아 온 원본은 가족 공동의 기록이라 이름을 바꾸는 것은 OWNER만
     * 한다. 편집본은 구성원이 직접 만든 결과물이므로 구성원도 이름을 고친다.
     * 즐겨찾기는 어느 쪽이든 구성원에게 열어 둔다 — 보기 표시를 못 하게 막을
     * 이유가 없다.
     */
    @Transactional
    public VideoResponse update(UUID userId, UUID videoId, UpdateVideoRequest request) {
        validate(request);
        VideoRow video = videoMapper.lockAccessibleVideo(userId, videoId).orElseThrow(this::notFound);
        String role = videoMapper.findActiveRole(userId, videoId).orElseThrow(this::notFound);
        boolean owner = "OWNER".equals(role);
        boolean member = owner || "MEMBER".equals(role);
        if (!member) {
            denyUpdate(video.deviceId(), userId, videoId, "OWNER 또는 MEMBER 권한이 필요합니다.");
        }
        boolean renaming = request.titlePresent();
        if (renaming && !owner && !isEditOutput(video)) {
            denyUpdate(
                video.deviceId(), userId, videoId, "원본 영상의 제목은 OWNER만 바꿀 수 있습니다.");
        }
        videoMapper.updateMetadata(
            videoId, request.titlePresent(), normalizedTitle(request),
            request.favoritePresent(), request.favorite());
        VideoResponse response = toResponse(
            videoMapper.findAccessibleVideo(userId, videoId).orElseThrow(this::notFound));
        auditService.success(video.deviceId(), userId, "VIDEO_UPDATE", "VIDEO", videoId);
        return response;
    }

    /**
     * 원본은 OWNER만 지운다. 지우면 가족 모두가 그 기록을 잃기 때문이다.
     *
     * 편집본은 자기가 만든 것을 스스로 지울 수 있어야 한다. 남의 편집본은
     * 건드리지 못하고, OWNER는 금고 전체를 정리할 수 있다.
     */
    @Transactional
    public void delete(UUID userId, UUID videoId) {
        VideoRow video = videoMapper.lockAccessibleVideo(userId, videoId).orElseThrow(this::notFound);
        String role = videoMapper.findActiveRole(userId, videoId).orElseThrow(this::notFound);
        boolean owner = "OWNER".equals(role);
        boolean ownEditOutput = isEditOutput(video)
            && userId.equals(videoMapper.findCreatorId(videoId).orElse(null));
        if (!owner && !ownEditOutput) {
            auditService.denied(
                video.deviceId(), userId, "VIDEO_DELETE", "VIDEO", videoId, "FORBIDDEN_ROLE");
            throw new ApiException(
                HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE",
                isEditOutput(video)
                    ? "자신이 만든 편집본이나 OWNER만 삭제할 수 있습니다."
                    : "OWNER만 원본 영상을 삭제할 수 있습니다.");
        }
        if (videoMapper.markDeleting(video.id(), userId) != 1) {
            throw notFound();
        }
        videoMapper.insertDeletionJob(video.id());
        auditService.success(video.deviceId(), userId, "VIDEO_DELETE", "VIDEO", videoId);
    }

    private static boolean isEditOutput(VideoRow video) {
        return "EDIT_OUTPUT".equals(video.sourceType());
    }

    private void denyUpdate(UUID deviceId, UUID userId, UUID videoId, String message) {
        auditService.denied(deviceId, userId, "VIDEO_UPDATE", "VIDEO", videoId, "FORBIDDEN_ROLE");
        throw new ApiException(HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE", message);
    }

    private void validate(UpdateVideoRequest request) {
        if (!request.titlePresent() && !request.favoritePresent()) {
            throw validation("수정할 필드를 하나 이상 입력해야 합니다.");
        }
        if (request.titlePresent()) {
            if (request.title() == null || request.title().trim().isEmpty() || request.title().trim().length() > 120) {
                throw validation("title은 공백이 아닌 1자 이상 120자 이하여야 합니다.");
            }
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
            video.title(), video.contentType(), video.sizeBytes(), video.checksumSha256(),
            video.durationMs(), video.capturedStartAt(), video.capturedEndAt(), video.status(), video.favorite(),
            null, video.createdAt(),
            VideoEventTypes.fromCsv(video.eventTypesCsv(), video.triggerType()));
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }

    private ApiException validation(String message) {
        return new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", message);
    }
}
