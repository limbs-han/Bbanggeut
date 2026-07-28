package com.wj.server.notification.api;

import java.util.List;
import java.util.UUID;

import com.wj.server.notification.application.NotificationService;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/notifications")
public class NotificationController {
    private final NotificationService service;

    public NotificationController(NotificationService service) {
        this.service = service;
    }

    @GetMapping
    public List<NotificationResponse> list(
        @AuthenticationPrincipal Jwt jwt,
        @RequestParam(defaultValue = "30") int limit
    ) {
        return service.list(userId(jwt), limit);
    }

    @GetMapping("/unread-count")
    public UnreadNotificationCountResponse unreadCount(@AuthenticationPrincipal Jwt jwt) {
        return new UnreadNotificationCountResponse(service.unreadCount(userId(jwt)));
    }

    @PatchMapping("/{notificationId}/read")
    public ResponseEntity<Void> markRead(
        @AuthenticationPrincipal Jwt jwt,
        @PathVariable UUID notificationId
    ) {
        service.markRead(userId(jwt), notificationId);
        return ResponseEntity.noContent().build();
    }

    @PatchMapping("/read-all")
    public ResponseEntity<Void> markAllRead(@AuthenticationPrincipal Jwt jwt) {
        service.markAllRead(userId(jwt));
        return ResponseEntity.noContent().build();
    }

    private UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
