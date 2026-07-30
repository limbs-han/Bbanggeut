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
