package com.wj.server.iot.telemetry;

import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.UUID;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.stream.application.StreamEventService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class MqttInboundHandlerTest {
    private static final Instant NOW = Instant.parse("2026-07-17T10:00:00Z");
    @Mock private DeviceTelemetryMapper telemetryMapper;
    @Mock private StreamEventService streamEventService;
    private MqttInboundHandler handler;

    @BeforeEach
    void setUp() {
        handler = new MqttInboundHandler(new ObjectMapper(), telemetryMapper, streamEventService,
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void recordsValidHeartbeatForTopicDevice() {
        UUID deviceId = UUID.randomUUID();
        handle(deviceId, "heartbeat", """
            {"schemaVersion":"1.0","deviceId":"%s","recording":true,
             "uploadQueueDepth":2,"bufferSeconds":120,"personCount":3,"firmwareVersion":"0.4.0"}
            """.formatted(deviceId));

        verify(telemetryMapper).recordHeartbeat(deviceId, true, 2, 120, 3, "0.4.0");
    }

    @Test
    void ignoresPayloadWhoseDeviceDoesNotMatchTopic() {
        UUID topicDeviceId = UUID.randomUUID();
        handle(topicDeviceId, "heartbeat", """
            {"schemaVersion":"1.0","deviceId":"%s","recording":true,"uploadQueueDepth":2}
            """.formatted(UUID.randomUUID()));

        verify(telemetryMapper, never()).recordHeartbeat(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyBoolean(),
            org.mockito.ArgumentMatchers.anyInt(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any());
    }

    @Test
    void acceptsRegistrationOnlyWithinFiveMinutes() {
        UUID deviceId = UUID.randomUUID();
        handle(deviceId, "registration", """
            {"schemaVersion":"1.0","deviceId":"%s","mode":"ENABLED",
             "expiresAt":"2026-07-17T10:02:00Z"}
            """.formatted(deviceId));

        verify(telemetryMapper).updateRegistrationMode(deviceId, Instant.parse("2026-07-17T10:02:00Z"));
    }

    @Test
    void routesReadyStreamEvent() {
        UUID deviceId = UUID.randomUUID();
        UUID streamId = UUID.randomUUID();
        handle(deviceId, "stream/events", """
            {"schemaVersion":"1.0","deviceId":"%s","streamId":"%s",
             "type":"STREAM_READY","hardExpiresAt":"2026-07-17T10:02:00Z"}
            """.formatted(deviceId, streamId));

        verify(streamEventService).ready(deviceId, streamId, Instant.parse("2026-07-17T10:02:00Z"));
    }

    private void handle(UUID deviceId, String suffix, String json) {
        handler.handle(("local/wj/v1/devices/" + deviceId + "/" + suffix),
            json.getBytes(StandardCharsets.UTF_8));
    }
}
