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

/** Vault administration stays auditable while no device is attached. */
@RestController
@RequestMapping("/api/vaults/{vaultId}/access-logs")
public class VaultAccessLogController {
    private final AccessLogQueryService queryService;

    public VaultAccessLogController(AccessLogQueryService queryService) {
        this.queryService = queryService;
    }

    @GetMapping
    public AccessLogPageResponse list(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId,
        @RequestParam(required = false) String cursor,
        @RequestParam(defaultValue = "20") int size
    ) {
        return queryService.listForVault(
            UUID.fromString(jwt.getSubject()), vaultId, cursor, size);
    }
}
