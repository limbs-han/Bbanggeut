package com.wj.server.notification.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.Optional;
import java.util.UUID;

import com.wj.server.notification.api.UpdateNotificationPreferencesRequest;
import com.wj.server.notification.domain.NotificationPreferenceRow;
import com.wj.server.notification.persistence.NotificationPreferenceMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class NotificationPreferenceServiceTest {
    @Mock
    private NotificationPreferenceMapper mapper;

    @Test
    void missingRowMeansEverythingEnabled() {
        UUID userId = UUID.randomUUID();
        when(mapper.findForUser(userId)).thenReturn(Optional.empty());

        var result = new NotificationPreferenceService(mapper).get(userId);

        assertThat(result.anniversaryAlerts()).isTrue();
        assertThat(result.weeklyReport()).isTrue();
        assertThat(result.newMemoryAlerts()).isTrue();
    }

    @Test
    void getReturnsStoredRow() {
        UUID userId = UUID.randomUUID();
        when(mapper.findForUser(userId)).thenReturn(Optional.of(
            new NotificationPreferenceRow(false, true, false)));

        var result = new NotificationPreferenceService(mapper).get(userId);

        assertThat(result.anniversaryAlerts()).isFalse();
        assertThat(result.weeklyReport()).isTrue();
        assertThat(result.newMemoryAlerts()).isFalse();
    }

    @Test
    void updateUpsertsAndEchoesValues() {
        UUID userId = UUID.randomUUID();

        var result = new NotificationPreferenceService(mapper).update(userId,
            new UpdateNotificationPreferencesRequest(true, false, true));

        verify(mapper).upsert(userId, true, false, true);
        assertThat(result.weeklyReport()).isFalse();
    }
}
