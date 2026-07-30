package com.wj.server.notification.application;

import java.util.List;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import com.wj.server.notification.api.NotificationResponse;
import com.wj.server.notification.persistence.NotificationMapper;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class NotificationService {
    private final NotificationMapper mapper;
    private final PushNotificationDispatcher pushDispatcher;

    public NotificationService(
        NotificationMapper mapper,
        PushNotificationDispatcher pushDispatcher
    ) {
        this.mapper = mapper;
        this.pushDispatcher = pushDispatcher;
    }

    @Transactional
    public void invitationReceived(
        String email, UUID deviceId, String deviceName, UUID invitationId
    ) {
        int inserted = mapper.insertInvitationNotification(
            UUID.randomUUID(), email, deviceId, deviceName, invitationId);
        if (inserted > 0) {
            pushDispatcher.invitationReceived(email, deviceId, deviceName, invitationId);
        }
    }

    @Transactional
    public void vaultInvitationReceived(
        String email, UUID vaultId, String vaultName, UUID invitationId
    ) {
        int inserted = mapper.insertVaultInvitationNotification(
            UUID.randomUUID(), email, vaultId, vaultName, invitationId);
        if (inserted > 0) {
            pushDispatcher.vaultInvitationReceived(
                email, vaultId, vaultName, invitationId);
        }
    }

    @Transactional
    public void laughterVideoReady(UUID deviceId, UUID videoId, String title) {
        int inserted = mapper.insertLaughterVideoNotifications(deviceId, videoId, title);
        if (inserted > 0) {
            pushDispatcher.laughterVideoReady(deviceId, videoId, title);
        }
    }

    @Transactional(readOnly = true)
    public List<NotificationResponse> list(UUID userId, int limit) {
        int safeLimit = Math.max(1, Math.min(limit, 100));
        return mapper.findForUser(userId, safeLimit).stream()
            .map(row -> new NotificationResponse(
                row.id(), row.type(), row.title(), row.body(), row.deviceId(),
                row.vaultId(), row.resourceId(), row.readAt(), row.createdAt()))
            .toList();
    }

    @Transactional(readOnly = true)
    public long unreadCount(UUID userId) {
        return mapper.countUnread(userId);
    }

    @Transactional
    public void markRead(UUID userId, UUID notificationId) {
        if (mapper.markRead(userId, notificationId) != 1) {
            throw new ApiException(
                HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "알림을 찾을 수 없습니다.");
        }
    }

    @Transactional
    public void markAllRead(UUID userId) {
        mapper.markAllRead(userId);
    }
}
