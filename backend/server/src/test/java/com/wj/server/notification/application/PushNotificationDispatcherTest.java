package com.wj.server.notification.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.List;
import java.util.UUID;

import com.wj.server.notification.domain.PushMessage;
import com.wj.server.notification.persistence.PushTokenMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.transaction.support.TransactionSynchronizationManager;

@ExtendWith(MockitoExtension.class)
class PushNotificationDispatcherTest {
    @Mock
    private PushTokenMapper tokenMapper;
    @Mock
    private PushGateway gateway;

    @Test
    void sendsAfterTransactionCommitAndDeletesInvalidTokens() {
        UUID deviceId = UUID.randomUUID();
        UUID videoId = UUID.randomUUID();
        when(tokenMapper.findActiveTokensByDevice(deviceId))
            .thenReturn(List.of("valid", "expired"));
        when(gateway.send(eq(List.of("valid", "expired")), any(PushMessage.class)))
            .thenReturn(List.of("expired"));
        var dispatcher = new PushNotificationDispatcher(tokenMapper, gateway);

        TransactionSynchronizationManager.initSynchronization();
        try {
            dispatcher.laughterVideoReady(deviceId, videoId, "웃음 영상");
            verify(gateway, never()).send(any(), any());

            var synchronizations = TransactionSynchronizationManager.getSynchronizations();
            assertThat(synchronizations).hasSize(1);
            synchronizations.get(0).afterCommit();
        } finally {
            TransactionSynchronizationManager.clearSynchronization();
        }

        var message = ArgumentCaptor.forClass(PushMessage.class);
        verify(gateway).send(eq(List.of("valid", "expired")), message.capture());
        assertThat(message.getValue().data())
            .containsEntry("type", "LAUGHTER_VIDEO_READY")
            .containsEntry("resourceId", videoId.toString());
        verify(tokenMapper).deleteTokens(List.of("expired"));
    }

    @Test
    void noTokenSkipsGateway() {
        when(tokenMapper.findActiveTokensByEmail("member@example.com"))
            .thenReturn(List.of());

        new PushNotificationDispatcher(tokenMapper, gateway).invitationReceived(
            "member@example.com", UUID.randomUUID(), "거실", UUID.randomUUID());

        verify(gateway, never()).send(any(), any());
    }
}
