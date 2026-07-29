package com.wj.server.video.api;

import java.util.UUID;
import java.time.Instant;

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
import com.wj.server.common.api.ApiException;
import org.springframework.http.HttpStatus;

@RestController
@RequestMapping("/api/videos")
public class VideoController {
    private final VideoQueryService videoQueryService;
    private final VideoCommandService videoCommandService;

    public VideoController(
        VideoQueryService videoQueryService,
        VideoCommandService videoCommandService
    ) {
        this.videoQueryService = videoQueryService;
        this.videoCommandService = videoCommandService;
    }

    @GetMapping
    public VideoPageResponse list(
        @AuthenticationPrincipal Jwt jwt,
        @RequestParam(required = false) UUID deviceId,
        @RequestParam(required = false) UUID vaultId,
        @RequestParam(required = false) String triggerType,
        @RequestParam(required = false) Instant from,
        @RequestParam(required = false) Instant to,
        @RequestParam(required = false) String cursor,
        @RequestParam(defaultValue = "20") int size
    ) {
        if ((deviceId == null) == (vaultId == null)) {
            throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY,
                "VALIDATION_FAILED",
                "deviceId 또는 vaultId 중 하나만 입력해야 합니다.");
        }
        return vaultId == null
            ? videoQueryService.list(
                userId(jwt), deviceId, triggerType, from, to, cursor, size)
            : videoQueryService.listByVault(
                userId(jwt), vaultId, triggerType, from, to, cursor, size);
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

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
