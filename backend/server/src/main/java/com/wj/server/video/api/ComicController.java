package com.wj.server.video.api;

import java.util.UUID;

import com.wj.server.video.application.ComicGatewayService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * API-71·API-72. 만화 만들기는 두 번의 호출로 나뉜다. 구성(글)을 먼저 보여 주고
 * 사용자가 대사를 고친 뒤 그림을 받게 하려고 그렸다.
 */
@RestController
@RequestMapping("/api/videos")
public class ComicController {
    private final ComicGatewayService comicGatewayService;

    public ComicController(ComicGatewayService comicGatewayService) {
        this.comicGatewayService = comicGatewayService;
    }

    @PostMapping("/{videoId}/comic/script")
    public ComicScriptResponse script(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @RequestBody ComicScriptRequest request
    ) {
        return comicGatewayService.createScript(
            userId(jwt), jwt.getTokenValue(), videoId, request);
    }

    @PostMapping("/{videoId}/comic/image")
    public ComicImageResponse image(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @RequestBody ComicImageRequest request
    ) {
        return comicGatewayService.createImage(
            userId(jwt), jwt.getTokenValue(), videoId, request);
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
