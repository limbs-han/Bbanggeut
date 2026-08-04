package com.wj.server.notification.application;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.wj.server.notification.domain.PushMessage;
import com.wj.server.notification.persistence.PushTokenMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

@Service
public class PushNotificationDispatcher {
    private static final Logger log = LoggerFactory.getLogger(PushNotificationDispatcher.class);

    private final PushTokenMapper tokenMapper;
    private final PushGateway gateway;

    public PushNotificationDispatcher(PushTokenMapper tokenMapper, PushGateway gateway) {
        this.tokenMapper = tokenMapper;
        this.gateway = gateway;
    }

    public void invitationReceived(
        String email, UUID deviceId, String deviceName, UUID invitationId
    ) {
        dispatchAfterCommit(
            () -> tokenMapper.findActiveTokensByEmail(email),
            new PushMessage(
                "새로운 기기 초대",
                deviceName + " 기기에 초대되었습니다.",
                Map.of(
                    "type", "INVITATION_RECEIVED",
                    "deviceId", deviceId.toString(),
                    "resourceId", invitationId.toString())));
    }

    public void vaultInvitationReceived(
        String email, UUID vaultId, String vaultName, UUID invitationId
    ) {
        dispatchAfterCommit(
            () -> tokenMapper.findActiveTokensByEmail(email),
            new PushMessage(
                "새로운 Vault 초대",
                vaultName + " Vault에 초대되었습니다.",
                Map.of(
                    "type", "INVITATION_RECEIVED",
                    "vaultId", vaultId.toString(),
                    "resourceId", invitationId.toString())));
    }

    public void invitationAccepted(
        UUID inviterId, String memberName, UUID invitationId
    ) {
        dispatchAfterCommit(
            () -> tokenMapper.findActiveTokensByUser(inviterId),
            new PushMessage(
                "초대를 수락했어요",
                memberName + " 님이 초대를 수락하고 가족이 되었어요.",
                Map.of(
                    "type", "INVITATION_ACCEPTED",
                    "resourceId", invitationId.toString())));
    }

    public void laughterVideoReady(UUID deviceId, UUID videoId, String title) {
        dispatchAfterCommit(
            () -> tokenMapper.findActiveTokensByDevice(deviceId),
            new PushMessage(
                "웃음 영상이 도착했어요",
                title,
                Map.of(
                    "type", "LAUGHTER_VIDEO_READY",
                    "deviceId", deviceId.toString(),
                    "resourceId", videoId.toString())));
    }

    /** 기념일(일정 D-day) — 일정을 등록한 사용자에게 보낸다. */
    public void anniversary(UUID userId, UUID scheduleId, String title, String body) {
        dispatchAfterCommit(
            () -> tokenMapper.findActiveTokensByUser(userId),
            new PushMessage(
                title,
                body,
                Map.of(
                    "type", "ANNIVERSARY",
                    "resourceId", scheduleId.toString())));
    }

    /** 주간 웃음 리포트 — 대상 사용자에게 보낸다. */
    public void weeklyReport(UUID userId, String body) {
        dispatchAfterCommit(
            () -> tokenMapper.findActiveTokensByUser(userId),
            new PushMessage(
                "주간 웃음 리포트",
                body,
                Map.of("type", "WEEKLY_REPORT")));
    }

    /** 편집 서버 분석 완료 — 분석을 요청한 사용자에게만 보낸다. */
    public void editAnalysisReady(UUID userId, UUID videoId) {
        dispatchAfterCommit(
            () -> tokenMapper.findActiveTokensByUser(userId),
            new PushMessage(
                "AI 분석이 끝났어요",
                "편집기에서 AI 컷과 자동 줌을 쓸 수 있어요",
                Map.of(
                    "type", "EDIT_ANALYSIS_READY",
                    "resourceId", videoId.toString())));
    }

    /** 편집 영상 새 댓글 — 작성자를 뺀 금고 구성원 전체에게 보낸다. */
    public void editCommentAdded(UUID actorUserId, UUID videoId, String body) {
        dispatchAfterCommit(
            () -> tokenMapper.findActiveTokensByVideoExcluding(videoId, actorUserId),
            new PushMessage(
                "가족이 편집 영상에 댓글을 남겼어요",
                body,
                Map.of(
                    "type", "EDIT_COMMENT_ADDED",
                    "resourceId", videoId.toString())));
    }

    private void dispatchAfterCommit(TokenSupplier tokenSupplier, PushMessage message) {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(
                new TransactionSynchronization() {
                    @Override
                    public void afterCommit() {
                        sendSafely(tokenSupplier, message);
                    }
                });
            return;
        }
        sendSafely(tokenSupplier, message);
    }

    private void sendSafely(TokenSupplier tokenSupplier, PushMessage message) {
        try {
            List<String> tokens = tokenSupplier.get();
            if (tokens.isEmpty()) {
                return;
            }
            List<String> invalidTokens = gateway.send(tokens, message);
            if (!invalidTokens.isEmpty()) {
                tokenMapper.deleteTokens(invalidTokens);
            }
        } catch (RuntimeException exception) {
            log.error("Push notification delivery failed for type={}",
                message.data().get("type"), exception);
        }
    }

    @FunctionalInterface
    private interface TokenSupplier {
        List<String> get();
    }
}
