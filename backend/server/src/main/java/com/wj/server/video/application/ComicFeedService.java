package com.wj.server.video.application;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.video.api.ComicLikeResponse;
import com.wj.server.video.api.CreateVideoCommentRequest;
import com.wj.server.video.api.UpdateComicRequest;
import com.wj.server.video.api.UpdateVideoCommentRequest;
import com.wj.server.video.api.VaultComicResponse;
import com.wj.server.video.api.VideoCommentResponse;
import com.wj.server.video.domain.ComicRow;
import com.wj.server.video.domain.VideoCommentRow;
import com.wj.server.video.persistence.ComicMapper;
import com.wj.server.video.persistence.VideoMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 만화 피드 — 목록, 제목, 좋아요, 댓글.
 *
 * <p>만화는 영상 하나에 하나이므로 식별자가 videoId다. 접근 권한도 그 영상의
 * 권한을 그대로 쓴다({@link VideoMapper#findAccessibleVideo}) — 만화만 따로
 * 열어 주거나 막는 개념을 두지 않는다.
 */
@Service
public class ComicFeedService {
    private static final int MAX_FEED_SIZE = 100;
    private static final int MAX_COMMENTS = 200;

    private final ComicMapper comicMapper;
    private final VideoMapper videoMapper;

    public ComicFeedService(ComicMapper comicMapper, VideoMapper videoMapper) {
        this.comicMapper = comicMapper;
        this.videoMapper = videoMapper;
    }

    /** 만화가 완성됐다. 이미 있으면 만든 시각을 덮지 않는다. */
    @Transactional
    public void register(UUID videoId) {
        comicMapper.upsert(videoId);
    }

    @Transactional(readOnly = true)
    public List<VaultComicResponse> listByVault(UUID userId, UUID vaultId) {
        return comicMapper.findByVault(userId, vaultId, MAX_FEED_SIZE).stream()
            .map(ComicFeedService::toResponse)
            .toList();
    }

    @Transactional
    public VaultComicResponse updateTitle(
        UUID userId, UUID videoId, UpdateComicRequest request
    ) {
        requireComic(userId, videoId);
        String title = request.title() == null || request.title().isBlank()
            ? null
            : request.title().strip();
        comicMapper.updateTitle(videoId, title);
        return toResponse(requireComic(userId, videoId));
    }

    /**
     * 좋아요를 켜거나 끈다. 같은 값을 두 번 보내도 결과가 같다 — 앱이 연타하거나
     * 응답을 놓쳐 다시 보내도 개수가 어긋나지 않는다.
     */
    @Transactional
    public ComicLikeResponse setLiked(UUID userId, UUID videoId, boolean liked) {
        requireComic(userId, videoId);
        if (liked) {
            comicMapper.like(videoId, userId);
        } else {
            comicMapper.unlike(videoId, userId);
        }
        ComicRow row = requireComic(userId, videoId);
        return new ComicLikeResponse(row.likeCount(), row.likedByMe());
    }

    @Transactional(readOnly = true)
    public List<VideoCommentResponse> listComments(UUID userId, UUID videoId) {
        requireComic(userId, videoId);
        return comicMapper.findComments(videoId, MAX_COMMENTS).stream()
            .map(row -> new VideoCommentResponse(
                row.id(), row.authorId(), row.authorName(), row.body(), row.createdAt()))
            .toList();
    }

    @Transactional
    public VideoCommentResponse addComment(
        UUID userId, UUID videoId, CreateVideoCommentRequest request
    ) {
        requireComic(userId, videoId);
        String body = requireBody(request.body());
        UUID commentId = UUID.randomUUID();
        comicMapper.insertComment(commentId, videoId, userId, body);
        return storedComment(commentId, videoId);
    }

    /** 댓글은 쓴 사람만 고친다(영상 댓글과 같은 규칙). */
    @Transactional
    public VideoCommentResponse updateComment(
        UUID userId, UUID videoId, UUID commentId, UpdateVideoCommentRequest request
    ) {
        requireComic(userId, videoId);
        UUID authorId = comicMapper.findCommentAuthorId(commentId, videoId)
            .orElseThrow(ComicFeedService::notFound);
        if (!userId.equals(authorId)) {
            throw new ApiException(
                HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE", "자신이 쓴 댓글만 고칠 수 있습니다.");
        }
        String body = requireBody(request.body());
        if (comicMapper.updateCommentBody(commentId, videoId, body) != 1) {
            throw notFound();
        }
        return storedComment(commentId, videoId);
    }

    /** 쓴 사람은 자기 댓글을, OWNER는 금고의 어느 댓글이든 지운다. */
    @Transactional
    public void deleteComment(UUID userId, UUID videoId, UUID commentId) {
        requireComic(userId, videoId);
        UUID authorId = comicMapper.findCommentAuthorId(commentId, videoId)
            .orElseThrow(ComicFeedService::notFound);
        boolean owner = "OWNER".equals(
            videoMapper.findActiveRole(userId, videoId).orElseThrow(ComicFeedService::notFound));
        if (!userId.equals(authorId) && !owner) {
            throw new ApiException(
                HttpStatus.FORBIDDEN, "FORBIDDEN_ROLE",
                "자신이 쓴 댓글이거나 OWNER만 삭제할 수 있습니다.");
        }
        if (comicMapper.deleteComment(commentId, videoId) != 1) {
            throw notFound();
        }
    }

    /**
     * 이 사람이 볼 수 있는 만화인가. 영상 권한을 먼저 보고, 그 다음 만화 행이
     * 있는지 본다 — 순서를 바꾸면 남의 금고 영상에 만화가 있는지를 404와 403의
     * 차이로 알아낼 수 있다.
     */
    private ComicRow requireComic(UUID userId, UUID videoId) {
        videoMapper.findAccessibleVideo(userId, videoId)
            .orElseThrow(ComicFeedService::notFound);
        return comicMapper.find(userId, videoId).orElseThrow(ComicFeedService::notFound);
    }

    private static String requireBody(String raw) {
        String body = raw == null ? "" : raw.strip();
        if (body.isEmpty()) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY, "VALIDATION_FAILED", "댓글 내용을 입력해야 합니다.");
        }
        return body;
    }

    private static VaultComicResponse toResponse(ComicRow row) {
        boolean custom = row.title() != null && !row.title().isBlank();
        String shown = custom
            ? row.title()
            : (row.sourceTitle() == null || row.sourceTitle().isBlank()
                ? "4컷 만화" : row.sourceTitle());
        return new VaultComicResponse(
            row.videoId(), shown, custom, row.madeAt(),
            row.likeCount(), row.likedByMe(), row.commentCount());
    }

    /// 저장된 댓글을 그대로 읽어 응답으로 쓴다. 이름은 users 조인에서 오고
    /// 시각은 DB가 찍은 값이라, 방금 쓴 댓글도 목록과 똑같이 보인다.
    private VideoCommentResponse storedComment(UUID commentId, UUID videoId) {
        VideoCommentRow row = comicMapper.findComment(commentId, videoId)
            .orElseThrow(ComicFeedService::notFound);
        return new VideoCommentResponse(
            row.id(), row.authorId(), row.authorName(), row.body(), row.createdAt());
    }

    private static ApiException notFound() {
        return new ApiException(
            HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }
}
