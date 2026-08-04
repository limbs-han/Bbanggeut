package com.wj.server.video.api;

import java.util.List;
import java.util.UUID;

import com.wj.server.video.application.EditedVideoService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.ResponseStatus;

@RestController
public class EditedVideoController {
    private final EditedVideoService service;

    public EditedVideoController(EditedVideoService service) {
        this.service = service;
    }

    /** 편집 완성본 업로드 예약. 응답의 서명 URL로 앱 백그라운드 작업이 PUT한다. */
    @PostMapping("/api/videos/{videoId}/edits")
    @ResponseStatus(HttpStatus.CREATED)
    public EditUploadResponse createEditUpload(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @Valid @RequestBody CreateEditUploadRequest request
    ) {
        return service.createUpload(userId(jwt), videoId, request);
    }

    /** 금고의 편집 완성본 목록(최신순). */
    @GetMapping("/api/vaults/{vaultId}/edits")
    public List<VideoResponse> listEdits(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId
    ) {
        return service.listByVault(userId(jwt), vaultId);
    }

    @GetMapping("/api/videos/{videoId}/comments")
    public List<VideoCommentResponse> listComments(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId
    ) {
        return service.listComments(userId(jwt), videoId);
    }

    @PostMapping("/api/videos/{videoId}/comments")
    @ResponseStatus(HttpStatus.CREATED)
    public VideoCommentResponse addComment(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @Valid @RequestBody CreateVideoCommentRequest request
    ) {
        return service.addComment(userId(jwt), videoId, request);
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
