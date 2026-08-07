package com.wj.server.audit.api;

import java.util.UUID;

import com.wj.server.audit.application.AccessLogQueryService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/devices/{deviceId}/access-logs")
public class AccessLogController {
    private final AccessLogQueryService queryService;

    public AccessLogController(AccessLogQueryService queryService) {
        this.queryService = queryService;
    }

    @GetMapping
    public AccessLogPageResponse list(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId,
        @RequestParam(required = false) String cursor,
        @RequestParam(defaultValue = "20") int size
    ) {
        return queryService.list(UUID.fromString(jwt.getSubject()), deviceId, cursor, size);
    }
}
