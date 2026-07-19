package com.wj.server.video.api;

import java.util.UUID;

import com.wj.server.video.application.VideoQueryService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.http.ResponseEntity;
import jakarta.validation.Valid;
import com.wj.server.video.application.VideoCommandService;
import com.wj.server.video.application.VideoEditService;

@RestController
@RequestMapping("/api/videos")
public class VideoController {
    private final VideoQueryService videoQueryService;
    private final VideoCommandService videoCommandService;
    private final VideoEditService videoEditService;

    public VideoController(
        VideoQueryService videoQueryService,
        VideoCommandService videoCommandService,
        VideoEditService videoEditService
    ) {
        this.videoQueryService = videoQueryService;
        this.videoCommandService = videoCommandService;
        this.videoEditService = videoEditService;
    }

    @GetMapping
    public VideoPageResponse list(
        @AuthenticationPrincipal Jwt jwt,
        @RequestParam UUID deviceId,
        @RequestParam(required = false) String triggerType,
        @RequestParam(required = false) String cursor,
        @RequestParam(defaultValue = "20") int size
    ) {
        return videoQueryService.list(userId(jwt), deviceId, triggerType, cursor, size);
    }

    @GetMapping("/{videoId}")
    public VideoResponse get(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID videoId) {
        return videoQueryService.get(userId(jwt), videoId);
    }

    @PatchMapping("/{videoId}")
    public VideoResponse update(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @Valid @RequestBody UpdateVideoRequest request
    ) {
        return videoCommandService.update(userId(jwt), videoId, request);
    }

    @DeleteMapping("/{videoId}")
    public ResponseEntity<Void> delete(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID videoId) {
        videoCommandService.delete(userId(jwt), videoId);
        return ResponseEntity.accepted().build();
    }

    @PostMapping("/{videoId}/play-url")
    public SignedUrlResponse playUrl(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID videoId) {
        return videoQueryService.createReadUrl(userId(jwt), videoId, false);
    }

    @PostMapping("/{videoId}/download-url")
    public SignedUrlResponse downloadUrl(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID videoId) {
        return videoQueryService.createReadUrl(userId(jwt), videoId, true);
    }

    @PostMapping("/{videoId}/edits")
    public ResponseEntity<VideoEditResponse> createEdit(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @Valid @RequestBody CreateVideoEditRequest request
    ) {
        return ResponseEntity.accepted().body(videoEditService.create(userId(jwt), videoId, request));
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
