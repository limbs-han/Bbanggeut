package com.wj.server.vault.api;

import java.util.List;
import java.util.UUID;

import com.wj.server.vault.application.VaultService;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/vaults")
public class VaultController {
    private final VaultService service;

    public VaultController(VaultService service) {
        this.service = service;
    }

    @GetMapping
    public List<VaultResponse> list(@AuthenticationPrincipal Jwt jwt) {
        return service.list(userId(jwt));
    }

    @GetMapping("/{vaultId}")
    public VaultResponse get(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId
    ) {
        return service.get(userId(jwt), vaultId);
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public VaultResponse create(
        @AuthenticationPrincipal Jwt jwt,
        @Valid @RequestBody CreateVaultRequest request
    ) {
        return service.create(userId(jwt), request.name());
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
