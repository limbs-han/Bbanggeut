package com.wj.server.video.api;

import java.time.LocalDate;
import java.util.UUID;

import com.wj.server.video.application.VideoStatsService;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/devices/{deviceId}/stats")
public class VideoStatsController {
    private final VideoStatsService service;

    public VideoStatsController(VideoStatsService service) {
        this.service = service;
    }

    @GetMapping
    public VideoStatsResponse get(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID deviceId,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to,
        @RequestParam(required = false) String timeZone
    ) {
        return service.get(UUID.fromString(jwt.getSubject()), deviceId, from, to, timeZone);
    }
}
