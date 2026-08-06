package com.wj.server.video.api;

import java.util.UUID;

import com.wj.server.video.application.VideoAnalysisService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/**
 * 영상 분석 상태 — 편집 화면과 만화 화면이 "분석 중"을 보여 주는 근거다.
 *
 * <p>앱이 워커(editor-api)에 직접 묻지 않고 여기로 온다. 워커는 진행 상태를
 * 메모리에만 들고 있어서 재배포하면 진행 중이던 분석이 사라져 보였다.
 */
@RestController
public class VideoAnalysisController {
    private final VideoAnalysisService service;

    public VideoAnalysisController(VideoAnalysisService service) {
        this.service = service;
    }

    /** 분석한 적이 없어도 200이고 {@code status: NONE}이다 — 404가 아니다. */
    @GetMapping("/api/videos/{videoId}/analysis")
    public VideoAnalysisResponse status(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID videoId
    ) {
        return service.status(UUID.fromString(jwt.getSubject()), videoId);
    }
}
