package com.wj.server.stream.api;

import java.util.UUID;

import com.wj.server.stream.application.StreamService;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class StreamController {
    private final StreamService service;

    public StreamController(StreamService service) {
        this.service = service;
    }

    @PostMapping("/devices/{deviceId}/stream-sessions")
    public ResponseEntity<StreamSessionResponse> create(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId
    ) {
        return ResponseEntity.accepted().body(service.create(userId(jwt), deviceId));
    }

    @GetMapping("/stream-sessions/{sessionId}")
    public StreamSessionResponse get(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID sessionId) {
        return service.get(userId(jwt), sessionId);
    }

    @DeleteMapping("/stream-sessions/{sessionId}")
    public ResponseEntity<Void> close(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID sessionId) {
        service.close(userId(jwt), sessionId);
        return ResponseEntity.noContent().build();
    }

    @PostMapping("/stream-sessions/{sessionId}/heartbeat")
    public ResponseEntity<Void> heartbeat(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID sessionId) {
        service.heartbeat(userId(jwt), sessionId);
        return ResponseEntity.noContent().build();
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
