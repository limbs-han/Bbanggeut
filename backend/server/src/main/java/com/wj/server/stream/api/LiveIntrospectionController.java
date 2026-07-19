package com.wj.server.stream.api;

import java.util.UUID;

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

    @GetMapping
    public ResponseEntity<Void> introspect(@RequestParam String token, @RequestParam UUID streamId) {
        return service.introspect(token, streamId)
            ? ResponseEntity.noContent().build()
            : ResponseEntity.status(401).build();
    }
}
