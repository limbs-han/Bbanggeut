package com.wj.server.vault.api;

import java.time.LocalDate;
import java.util.UUID;

import com.wj.server.vault.application.VaultEventStatsService;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/vaults/{vaultId}/event-stats")
public class VaultEventStatsController {
    private final VaultEventStatsService service;

    public VaultEventStatsController(VaultEventStatsService service) {
        this.service = service;
    }

    @GetMapping
    public VaultEventStatsResponse get(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to,
        @RequestParam(required = false) String timeZone,
        @RequestParam(required = false) String type
    ) {
        return service.get(UUID.fromString(jwt.getSubject()), vaultId, from, to, timeZone, type);
    }
}
