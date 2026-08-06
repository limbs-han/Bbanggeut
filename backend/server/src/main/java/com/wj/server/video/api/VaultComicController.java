package com.wj.server.video.api;

import java.util.List;
import java.util.UUID;

import com.wj.server.video.application.ComicFeedService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * 만화 피드 — 금고의 만화 목록과, 만화 하나에 붙는 제목·좋아요·댓글.
 *
 * <p>그림 자체는 {@link ComicController}가 워커에서 받아 온다. 여기는 그림을
 * 둘러싼 것만 다룬다.
 */
@RestController
public class VaultComicController {
    private final ComicFeedService service;

    public VaultComicController(ComicFeedService service) {
        this.service = service;
    }

    /** 금고의 만화 목록(최신순). 추억 탭의 만화 피드가 이것을 그린다. */
    @GetMapping("/api/vaults/{vaultId}/comics")
    public List<VaultComicResponse> list(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId
    ) {
        return service.listByVault(userId(jwt), vaultId);
    }

    /** 만화 제목 바꾸기. 빈 제목을 보내면 원본 영상 제목으로 되돌아간다. */
    @PatchMapping("/api/videos/{videoId}/comic")
    public VaultComicResponse updateTitle(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @Valid @RequestBody UpdateComicRequest request
    ) {
        return service.updateTitle(userId(jwt), videoId, request);
    }

    @PutMapping("/api/videos/{videoId}/comic/like")
    public ComicLikeResponse like(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId
    ) {
        return service.setLiked(userId(jwt), videoId, true);
    }

    @DeleteMapping("/api/videos/{videoId}/comic/like")
    public ComicLikeResponse unlike(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId
    ) {
        return service.setLiked(userId(jwt), videoId, false);
    }

    @GetMapping("/api/videos/{videoId}/comic/comments")
    public List<VideoCommentResponse> listComments(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId
    ) {
        return service.listComments(userId(jwt), videoId);
    }

    @PostMapping("/api/videos/{videoId}/comic/comments")
    @ResponseStatus(HttpStatus.CREATED)
    public VideoCommentResponse addComment(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @Valid @RequestBody CreateVideoCommentRequest request
    ) {
        return service.addComment(userId(jwt), videoId, request);
    }

    /** 댓글 수정. 쓴 사람만 할 수 있다. */
    @PatchMapping("/api/videos/{videoId}/comic/comments/{commentId}")
    public VideoCommentResponse updateComment(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @PathVariable UUID commentId,
        @Valid @RequestBody UpdateVideoCommentRequest request
    ) {
        return service.updateComment(userId(jwt), videoId, commentId, request);
    }

    /** 댓글 삭제. 쓴 사람 또는 금고 OWNER. */
    @DeleteMapping("/api/videos/{videoId}/comic/comments/{commentId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void deleteComment(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @PathVariable UUID commentId
    ) {
        service.deleteComment(userId(jwt), videoId, commentId);
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
