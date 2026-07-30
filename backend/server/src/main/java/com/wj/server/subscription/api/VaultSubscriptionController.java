package com.wj.server.subscription.api;

import java.util.UUID;

import com.wj.server.subscription.application.SubscriptionService;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** The subscription belongs to the vault, so it stays reachable with no device. */
@RestController
@RequestMapping("/api/vaults/{vaultId}/subscription")
public class VaultSubscriptionController {
    private final SubscriptionService subscriptionService;

    public VaultSubscriptionController(SubscriptionService subscriptionService) {
        this.subscriptionService = subscriptionService;
    }

    @GetMapping
    public SubscriptionResponse get(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId
    ) {
        return subscriptionService.getForVault(userId(jwt), vaultId);
    }

    @PutMapping
    public SubscriptionResponse activate(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId
    ) {
        return subscriptionService.activateForVault(userId(jwt), vaultId);
    }

    @DeleteMapping
    public SubscriptionResponse cancel(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID vaultId
    ) {
        return subscriptionService.cancelForVault(userId(jwt), vaultId);
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
