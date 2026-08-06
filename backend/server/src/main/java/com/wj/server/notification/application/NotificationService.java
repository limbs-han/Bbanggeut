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
    /** 목록 배지용이라 넉넉하면 충분하다 — 금고 하나의 만화가 이보다 많을 일은 없다. */

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

    /** 초대를 보낸 사람에게 수락 소식을 알린다. 초대자가 없으면 조용히 넘어간다. */
    @Transactional
    public void invitationAccepted(
        UUID inviterId, String memberName, UUID deviceId, UUID vaultId, UUID invitationId
    ) {
        if (inviterId == null) {
            return;
        }
        int inserted = mapper.insertInvitationAcceptedNotification(
            UUID.randomUUID(), inviterId, memberName, deviceId, vaultId, invitationId);
        if (inserted > 0) {
            pushDispatcher.invitationAccepted(inviterId, memberName, invitationId);
        }
    }

    /**
     * 감지로 담긴 영상이 도착했다 — 기기를 공유하는 가족 전원에게 알린다.
     * {@code headline}이 감지 유형(웃음·박수·호출·직접)을 말해 준다.
     */
    @Transactional
    public void videoArrived(UUID deviceId, UUID videoId, String headline, String title) {
        int inserted = mapper.insertVideoArrivedNotifications(
            deviceId, videoId, headline, title);
        if (inserted > 0) {
            pushDispatcher.videoArrived(deviceId, videoId, headline, title);
        }
    }

    /** 편집 서버 분석 완료 — 분석을 요청한 사용자에게만 알린다. */
    @Transactional
    public void editAnalysisReady(UUID userId, UUID videoId) {
        if (userId == null) {
            return;
        }
        int inserted = mapper.insertEditAnalysisReadyNotification(userId, videoId);
        if (inserted > 0) {
            pushDispatcher.editAnalysisReady(userId, videoId);
        }
    }

    /** 4컷 만화 완성 — 만들기를 누른 사람에게만 알린다. */
    @Transactional
    public void comicReady(UUID userId, UUID videoId) {
        if (userId == null) {
            return;
        }
        int inserted = mapper.insertComicReadyNotification(userId, videoId);
        if (inserted > 0) {
            pushDispatcher.comicReady(userId, videoId);
        }
    }

    /**
     * 만화 대사 구성 완료 — 만들기를 누른 사람에게만 알린다.
     *
     * <p>1단계는 동기 응답이지만 Gemini 호출이라 20초 가까이 걸린다. 그 사이
     * 화면을 벗어나면 대사가 준비된 것을 알 방법이 없어 처음부터 다시
     * 부르게 됐다 — 호출료가 두 번 든다.
     */
    @Transactional
    public void comicScriptReady(UUID userId, UUID videoId) {
        if (userId == null) {
            return;
        }
        int inserted = mapper.insertComicScriptReadyNotification(userId, videoId);
        if (inserted > 0) {
            pushDispatcher.comicScriptReady(userId, videoId);
        }
    }

    /** 편집 영상 새 댓글 — 작성자를 뺀 금고 구성원 전체에게 알린다. */
    @Transactional
    public void editCommentAdded(
        UUID actorUserId, UUID videoId, String commentId, String body
    ) {
        if (actorUserId == null || commentId == null || commentId.isBlank()) {
            return;
        }
        int inserted = mapper.insertEditCommentNotifications(
            videoId, actorUserId, body, commentId);
        if (inserted > 0) {
            pushDispatcher.editCommentAdded(actorUserId, videoId, body);
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
