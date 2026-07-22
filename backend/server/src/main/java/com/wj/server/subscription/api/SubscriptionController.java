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

@RestController
@RequestMapping("/api/devices/{deviceId}/subscription")
public class SubscriptionController {
    private final SubscriptionService subscriptionService;

    public SubscriptionController(SubscriptionService subscriptionService) {
        this.subscriptionService = subscriptionService;
    }

    @GetMapping
    public SubscriptionResponse get(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID deviceId) {
        return subscriptionService.get(userId(jwt), deviceId);
    }

    @PutMapping
    public SubscriptionResponse activate(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID deviceId) {
        return subscriptionService.activate(userId(jwt), deviceId);
    }

    @DeleteMapping
    public SubscriptionResponse cancel(@AuthenticationPrincipal Jwt jwt, @PathVariable UUID deviceId) {
        return subscriptionService.cancel(userId(jwt), deviceId);
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
