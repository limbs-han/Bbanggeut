package com.wj.server.laughdraw.api;

import java.util.List;
import java.util.UUID;

import com.wj.server.laughdraw.application.LaughDrawService;
import jakarta.validation.Valid;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 웃음 뽑기 API.
 *
 * <p>가족(=추억 금고) 경로는 빵긋이와 같은 {@code /api/families/{familyId}} 규칙을 따른다.
 */
@RestController
public class LaughDrawController {
    private final LaughDrawService service;

    public LaughDrawController(LaughDrawService service) {
        this.service = service;
    }

    @GetMapping("/api/families/{familyId}/laugh-memories/random")
    public LaughDrawResponse drawRandom(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID familyId,
        @RequestParam(required = false) Integer days,
        @RequestParam(required = false) List<UUID> excludeIds
    ) {
        return service.drawRandom(userId(jwt), familyId, days, excludeIds);
    }

    /** 앱이 기기에 적어 둔 "오늘 뽑은 영상"으로 결과 화면을 되살릴 때. */
    @GetMapping("/api/laugh-memories/{memoryId}")
    public LaughMemoryResponse get(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID memoryId
    ) {
        return service.findMemory(userId(jwt), memoryId);
    }

    @PutMapping("/api/laugh-memories/{memoryId}/reaction")
    public LaughMemoryResponse react(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID memoryId,
        @Valid @RequestBody LaughReactionRequest request
    ) {
        return service.react(userId(jwt), memoryId, request.reactionType());
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
