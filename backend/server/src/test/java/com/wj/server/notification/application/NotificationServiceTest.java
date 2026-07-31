package com.wj.server.notification.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.wj.server.notification.domain.NotificationRow;
import com.wj.server.notification.persistence.NotificationMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class NotificationServiceTest {
    @Mock
    private NotificationMapper mapper;
    @Mock
    private PushNotificationDispatcher pushDispatcher;

    @Test
    void listCapsLimitAndMapsRows() {
        UUID userId = UUID.randomUUID();
        UUID notificationId = UUID.randomUUID();
        when(mapper.findForUser(userId, 100)).thenReturn(List.of(new NotificationRow(
            notificationId, "INVITATION_RECEIVED", "초대", "새 초대",
            UUID.randomUUID(), null, UUID.randomUUID(), null,
            Instant.parse("2026-07-27T10:00:00Z"))));

        var result = new NotificationService(mapper, pushDispatcher).list(userId, 1_000);

        assertThat(result).hasSize(1);
        assertThat(result.get(0).id()).isEqualTo(notificationId);
    }

    @Test
    void laughterNotificationTargetsAllActiveMembershipsThroughMapper() {
        UUID deviceId = UUID.randomUUID();
        UUID videoId = UUID.randomUUID();

        when(mapper.insertLaughterVideoNotifications(deviceId, videoId, "웃음 영상"))
            .thenReturn(2);

        new NotificationService(mapper, pushDispatcher)
            .laughterVideoReady(deviceId, videoId, "웃음 영상");

        verify(mapper).insertLaughterVideoNotifications(deviceId, videoId, "웃음 영상");
        verify(pushDispatcher).laughterVideoReady(deviceId, videoId, "웃음 영상");
    }

    @Test
    void duplicateNotificationDoesNotSendPushAgain() {
        UUID deviceId = UUID.randomUUID();
        UUID videoId = UUID.randomUUID();
        when(mapper.insertLaughterVideoNotifications(deviceId, videoId, "웃음 영상"))
            .thenReturn(0);

        new NotificationService(mapper, pushDispatcher)
            .laughterVideoReady(deviceId, videoId, "웃음 영상");

        verifyNoInteractions(pushDispatcher);
    }
}
