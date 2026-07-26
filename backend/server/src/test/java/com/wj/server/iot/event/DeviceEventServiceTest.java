package com.wj.server.iot.event;

import static org.mockito.Mockito.verify;

import java.time.Instant;
import java.util.UUID;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class DeviceEventServiceTest {
    @Mock
    private DeviceEventMapper mapper;

    @Test
    void eventIsPersistedWithoutNotificationSideEffects() {
        DeviceEvent event = event("TOUCH");

        new DeviceEventService(mapper).accept(event);

        verify(mapper).insert(event);
    }

    private DeviceEvent event(String type) {
        return new DeviceEvent(
            UUID.randomUUID(), UUID.randomUUID(), type, Instant.parse("2026-07-17T10:00:00Z"),
            null, "QUEUED", 120000, 0, 0, "pi-gateway", "TOUCH_SENSOR", null);
    }
}
