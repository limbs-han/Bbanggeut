package com.wj.server.video.api;

import java.util.UUID;

import com.wj.server.video.application.ComicGatewayService;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
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

    /**
     * 그림 만들기를 백그라운드로 맡긴다(202). 화면을 벗어나도 계속되고, 끝나면
     * 알림이 온다.
     */
    @PutMapping("/{videoId}/comic/image")
    @ResponseStatus(HttpStatus.ACCEPTED)
    public ComicJobResponse enqueueImage(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId,
        @RequestBody ComicImageRequest request
    ) {
        return comicGatewayService.enqueueImage(
            userId(jwt), jwt.getTokenValue(), videoId, request);
    }

    /** 만화 작업 상태와, 다 됐으면 그림을 받을 단기 URL. */
    @GetMapping("/{videoId}/comic/image")
    public ComicJobResponse imageStatus(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId
    ) {
        return comicGatewayService.imageStatus(
            userId(jwt), jwt.getTokenValue(), videoId);
    }

    /**
     * 만화 지우기. 그림·구성과 피드 행(좋아요·댓글 포함)이 함께 사라진다.
     * 금고 OWNER만 할 수 있고, 원본 영상은 그대로 남는다.
     */
    @DeleteMapping("/{videoId}/comic")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId
    ) {
        comicGatewayService.deleteComic(userId(jwt), jwt.getTokenValue(), videoId);
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
