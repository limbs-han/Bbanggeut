package com.wj.server.video.application;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.config.SubscriptionProperties;
import com.wj.server.notification.application.NotificationService;
import com.wj.server.storage.ObjectStorageService;
import com.wj.server.video.api.CreateEditUploadRequest;
import com.wj.server.video.api.CreateVideoCommentRequest;
import com.wj.server.video.api.EditUploadResponse;
import com.wj.server.video.api.UpdateVideoCommentRequest;
import com.wj.server.video.api.VideoCommentResponse;
import com.wj.server.video.api.VideoResponse;
import com.wj.server.video.domain.VideoRow;
import com.wj.server.video.persistence.VideoCommentMapper;
import com.wj.server.video.persistence.VideoMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 편집 완성본과 그 댓글. 원본 영상과 같은 {@code videos} 테이블의
 * {@code EDIT_OUTPUT} 행으로 두어 권한·보관 만료·삭제 연쇄·목록을 원본과
 * 같은 경로로 처리한다.
 *
 * <p>업로드는 앱이 아니라 OS 백그라운드 작업(WorkManager)이 수행한다 —
 * 세션이 없으므로 서명된 URL만 넘기고, 완료 통보 대신 서버가 객체 도착을
 * 훑어 READY로 승격한다({@link EditUploadSweepWorker}).
 */
@Service
public class EditedVideoService {
    private static final int MAX_LIST_SIZE = 100;
    private static final int MAX_COMMENTS = 200;

    private final VideoMapper videoMapper;
    private final VideoCommentMapper commentMapper;
    private final ObjectStorageService objectStorageService;
    private final SubscriptionProperties subscriptionProperties;
    private final NotificationService notificationService;

    public EditedVideoService(
        VideoMapper videoMapper,
        VideoCommentMapper commentMapper,
        ObjectStorageService objectStorageService,
        SubscriptionProperties subscriptionProperties,
        NotificationService notificationService
    ) {
        this.videoMapper = videoMapper;
        this.commentMapper = commentMapper;
        this.objectStorageService = objectStorageService;
        this.subscriptionProperties = subscriptionProperties;
        this.notificationService = notificationService;
    }

    @Transactional
    public EditUploadResponse createUpload(
        UUID userId, UUID sourceVideoId, CreateEditUploadRequest request
    ) {
        VideoRow source = videoMapper.findAccessibleVideo(userId, sourceVideoId)
            .orElseThrow(this::notFound);
        UUID editVideoId = UUID.randomUUID();
        String storageKey = "private/" + source.deviceId() + "/edits/" + editVideoId + ".mp4";
        String title = normalizedTitle(request.title(), source.title());

        int inserted = videoMapper.insertEditOutput(
            editVideoId, sourceVideoId, userId, title, storageKey, request.durationMs(),
            request.capturedStartAt() != null ? request.capturedStartAt() : source.capturedStartAt(),
            request.capturedEndAt() != null ? request.capturedEndAt() : source.capturedEndAt(),
            subscriptionProperties.premiumRetentionDays());
        if (inserted != 1) {
            throw new ApiException(
                HttpStatus.CONFLICT, "VIDEO_STATE_CONFLICT",
                "원본 영상의 금고 연결을 확인할 수 없어 편집본을 등록하지 못했습니다.");
        }

        var upload = objectStorageService.createEditUploadUrl(storageKey, "video/mp4");
        return new EditUploadResponse(
            editVideoId, upload.url(), "PUT", upload.requiredHeaders(), upload.expiresAt());
    }

    @Transactional(readOnly = true)
    public List<VideoResponse> listByVault(UUID userId, UUID vaultId) {
        return videoMapper.findEditOutputsByVault(userId, vaultId, MAX_LIST_SIZE).stream()
            .map(this::toResponse)
            .toList();
    }

    @Transactional(readOnly = true)
    public List<VideoCommentResponse> listComments(UUID userId, UUID videoId) {
        videoMapper.findAccessibleVideo(userId, videoId).orElseThrow(this::notFound);
        return commentMapper.findForVideo(videoId, MAX_COMMENTS).stream()
            .map(row -> new VideoCommentResponse(
                row.id(), row.authorId(), row.authorName(), row.body(), row.createdAt()))
            .toList();
    }

    @Transactional
    public VideoCommentResponse addComment(
        UUID userId, UUID videoId, CreateVideoCommentRequest request
    ) {
        videoMapper.findAccessibleVideo(userId, videoId).orElseThrow(this::notFound);
        String body = request.body().strip();
        if (body.isEmpty()) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", "댓글 내용을 입력해야 합니다.");
        }
        UUID commentId = UUID.randomUUID();
        commentMapper.insert(commentId, videoId, userId, body);
        // 작성자를 뺀 금고 구성원에게 알림 + FCM.
        notificationService.editCommentAdded(userId, videoId, commentId.toString(), body);
        return new VideoCommentResponse(
            commentId, userId, null, body, Instant.now());
    }

    /**
     * 댓글은 쓴 사람만 고친다.
     *
     * OWNER에게도 열지 않은 이유는 남의 말을 고쳐 쓰는 것과 지우는 것이 다른
     * 일이기 때문이다. 부적절한 댓글은 {@link #deleteComment}로 지운다.
     */
    @Transactional
    public VideoCommentResponse updateComment(
        UUID userId, UUID videoId, UUID commentId, UpdateVideoCommentRequest request
    ) {
        videoMapper.findAccessibleVideo(userId, videoId).orElseThrow(this::notFound);
        UUID authorId = commentMapper.findAuthorId(commentId, videoId).orElseThrow(this::notFound);
        if (!userId.equals(authorId)) {
            throw new ApiException(
                HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE", "자신이 쓴 댓글만 고칠 수 있습니다.");
        }
        String body = request.body().strip();
        if (body.isEmpty()) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", "댓글 내용을 입력해야 합니다.");
        }
        if (commentMapper.updateBody(commentId, videoId, body) != 1) {
            throw notFound();
        }
        return new VideoCommentResponse(commentId, userId, null, body, Instant.now());
    }

    /** 쓴 사람은 자기 댓글을, OWNER는 금고의 어느 댓글이든 지운다. */
    @Transactional
    public void deleteComment(UUID userId, UUID videoId, UUID commentId) {
        videoMapper.findAccessibleVideo(userId, videoId).orElseThrow(this::notFound);
        UUID authorId = commentMapper.findAuthorId(commentId, videoId).orElseThrow(this::notFound);
        boolean owner = "OWNER".equals(
            videoMapper.findActiveRole(userId, videoId).orElseThrow(this::notFound));
        if (!userId.equals(authorId) && !owner) {
            throw new ApiException(
                HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE",
                "자신이 쓴 댓글이거나 OWNER만 삭제할 수 있습니다.");
        }
        if (commentMapper.delete(commentId, videoId) != 1) {
            throw notFound();
        }
    }

    private String normalizedTitle(String requested, String sourceTitle) {
        if (requested != null && !requested.isBlank()) {
            return requested.strip();
        }
        return sourceTitle == null || sourceTitle.isBlank() ? "편집 영상" : sourceTitle;
    }

    private VideoResponse toResponse(VideoRow video) {
        return new VideoResponse(
            video.id(), video.deviceId(), video.sourceType(), video.triggerType(),
            video.sourceEventId(), video.title(), video.description(), video.contentType(),
            video.sizeBytes(), video.checksumSha256(), video.durationMs(),
            video.capturedStartAt(), video.capturedEndAt(), video.status(),
            video.favorite(), null, video.createdAt(),
            com.wj.server.video.domain.VideoEventTypes.fromCsv(
                video.eventTypesCsv(), video.triggerType()));
    }

    private ApiException notFound() {
        return new ApiException(
            HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }
}
