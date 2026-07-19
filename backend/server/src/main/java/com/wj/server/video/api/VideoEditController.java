package com.wj.server.video.api;

import java.util.UUID;

import com.wj.server.video.application.VideoEditService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/video-edits")
public class VideoEditController {
    private final VideoEditService service;

    public VideoEditController(VideoEditService service) {
        this.service = service;
    }

    @GetMapping("/{editId}")
    public VideoEditResponse get(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID editId) {
        return service.get(UUID.fromString(jwt.getSubject()), editId);
    }
}
