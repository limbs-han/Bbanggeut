package com.wj.server.stream.api;

import java.util.UUID;

import com.wj.server.stream.application.LiveTokenService;
import com.wj.server.stream.application.StreamService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/live/introspect")
public class LiveIntrospectionController {
    private final StreamService service;

    public LiveIntrospectionController(StreamService service) {
        this.service = service;
    }

    /**
     * Nginx {@code auth_request}가 호출한다. WHEP 재생은 {@code scope=PLAY},
     * WHIP 발화는 {@code scope=TALK}로 오며 검증 규칙이 서로 다르다.
     */
    @GetMapping
    public ResponseEntity<Void> introspect(
        @RequestParam String token,
        @RequestParam UUID streamId,
        @RequestParam(defaultValue = "PLAY") String scope
    ) {
        LiveTokenService.Scope requested = LiveTokenService.Scope.parse(scope);
        return requested != null && service.introspect(token, streamId, requested)
            ? ResponseEntity.noContent().build()
            : ResponseEntity.status(401).build();
    }
}
