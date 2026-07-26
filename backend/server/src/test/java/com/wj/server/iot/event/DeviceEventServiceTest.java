package com.wj.server.iot.event;

import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

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
    void firstTouchEventQueuesOwnerEmail() {
        DeviceEvent event = event("TOUCH");
        when(mapper.insert(event)).thenReturn(1);

        new DeviceEventService(mapper).accept(event);

        verify(mapper).enqueueOwnerTouchEmail(event.id());
    }

    @Test
    void duplicateTouchEventDoesNotQueueDuplicateEmail() {
        DeviceEvent event = event("TOUCH");
        when(mapper.insert(event)).thenReturn(0);

        new DeviceEventService(mapper).accept(event);

        verify(mapper, never()).enqueueOwnerTouchEmail(event.id());
    }

    private DeviceEvent event(String type) {
        return new DeviceEvent(
            UUID.randomUUID(), UUID.randomUUID(), type, Instant.parse("2026-07-17T10:00:00Z"),
            null, "QUEUED", 120000, 0, 0, "pi-gateway", "TOUCH_SENSOR", null);
    }
}
