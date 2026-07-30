package com.wj.server.iot.telemetry;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class DeviceTelemetryServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-30T01:00:00Z");

    @Mock private DevicePresenceStore presenceStore;
    @Mock private DeviceTelemetryMapper telemetryMapper;
    private DeviceTelemetryService service;

    @BeforeEach
    void setUp() {
        service = new DeviceTelemetryService(
            presenceStore, telemetryMapper, Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void heartbeatUsesRedisWithoutUpdatingTheDeviceRow() {
        UUID deviceId = UUID.randomUUID();
        when(presenceStore.put(org.mockito.ArgumentMatchers.eq(deviceId), any())).thenReturn(true);

        service.recordHeartbeat(deviceId, true, 2, 120, 3, "0.4.0");

        ArgumentCaptor<DevicePresenceSnapshot> snapshot =
            ArgumentCaptor.forClass(DevicePresenceSnapshot.class);
        verify(presenceStore).put(org.mockito.ArgumentMatchers.eq(deviceId), snapshot.capture());
        assertThat(snapshot.getValue().lastSeenAt()).isEqualTo(NOW);
        assertThat(snapshot.getValue().recording()).isTrue();
        assertThat(snapshot.getValue().personCount()).isEqualTo(3);
        verify(telemetryMapper, never()).recordHeartbeat(
            any(), org.mockito.ArgumentMatchers.anyBoolean(),
            org.mockito.ArgumentMatchers.anyInt(), any(), any(), any());
    }

    @Test
    void heartbeatFallsBackToPostgresWhenRedisIsUnavailable() {
        UUID deviceId = UUID.randomUUID();
        when(presenceStore.put(org.mockito.ArgumentMatchers.eq(deviceId), any())).thenReturn(false);

        service.recordHeartbeat(deviceId, true, 2, 120, 3, "0.4.0");

        verify(telemetryMapper).recordHeartbeat(deviceId, true, 2, 120, 3, "0.4.0");
    }

    @Test
    void explicitOfflineStateIsDurableAndRemovesPresence() {
        UUID deviceId = UUID.randomUUID();

        service.recordConnectionState(deviceId, false, "0.4.0");

        verify(telemetryMapper).recordConnectionState(deviceId, false, "0.4.0");
        verify(presenceStore).remove(deviceId);
    }
}
