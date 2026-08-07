package com.wj.server.home.api;

import java.util.UUID;

import com.wj.server.home.application.HomeSummaryService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/devices/{deviceId}/home-summary")
public class HomeSummaryController {
    private final HomeSummaryService service;

    public HomeSummaryController(HomeSummaryService service) {
        this.service = service;
    }

    @GetMapping
    public HomeSummaryResponse get(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId,
        @RequestParam(required = false) String timeZone
    ) {
        return service.get(UUID.fromString(jwt.getSubject()), deviceId, timeZone);
    }
}
