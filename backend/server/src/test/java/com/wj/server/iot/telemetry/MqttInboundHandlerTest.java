package com.wj.server.iot.telemetry;

import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.ArgumentMatchers.argThat;

import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.UUID;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.iot.event.DeviceEventService;
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
    @Mock private DeviceTelemetryService telemetryService;
    @Mock private StreamEventService streamEventService;
    @Mock private DeviceEventService deviceEventService;
    private MqttInboundHandler handler;

    @BeforeEach
    void setUp() {
        handler = new MqttInboundHandler(
            new ObjectMapper(), telemetryMapper, telemetryService, streamEventService,
            deviceEventService,
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void recordsValidHeartbeatForTopicDevice() {
        UUID deviceId = UUID.randomUUID();
        handle(deviceId, "heartbeat", """
            {"schemaVersion":"2.0","deviceId":"%s","recording":true,
             "uploadQueueDepth":2,"bufferSeconds":120,"personCount":3,"firmwareVersion":"0.4.0"}
            """.formatted(deviceId));

        verify(telemetryService).recordHeartbeat(deviceId, true, 2, 120, 3, "0.4.0");
    }

    @Test
    void ignoresPayloadWhoseDeviceDoesNotMatchTopic() {
        UUID topicDeviceId = UUID.randomUUID();
        handle(topicDeviceId, "heartbeat", """
            {"schemaVersion":"2.0","deviceId":"%s","recording":true,"uploadQueueDepth":2}
            """.formatted(UUID.randomUUID()));

        verify(telemetryService, never()).recordHeartbeat(
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.anyBoolean(),
            org.mockito.ArgumentMatchers.anyInt(), org.mockito.ArgumentMatchers.any(),
            org.mockito.ArgumentMatchers.any(), org.mockito.ArgumentMatchers.any());
    }

    @Test
    void acceptsRegistrationOnlyWithinFiveMinutes() {
        UUID deviceId = UUID.randomUUID();
        handle(deviceId, "registration", """
            {"schemaVersion":"2.0","deviceId":"%s","mode":"ENABLED",
             "expiresAt":"2026-07-17T10:02:00Z"}
            """.formatted(deviceId));

        verify(telemetryMapper).updateRegistrationMode(deviceId, Instant.parse("2026-07-17T10:02:00Z"));
    }

    @Test
    void routesReadyStreamEvent() {
        UUID deviceId = UUID.randomUUID();
        UUID streamId = UUID.randomUUID();
        handle(deviceId, "stream/events", """
            {"schemaVersion":"2.0","deviceId":"%s","streamId":"%s",
             "type":"STREAM_READY","hardExpiresAt":"2026-07-17T10:02:00Z"}
            """.formatted(deviceId, streamId));

        verify(streamEventService).ready(deviceId, streamId, Instant.parse("2026-07-17T10:02:00Z"));
    }

    @Test
    void validatesAndPersistsTouchEvent() {
        UUID deviceId = UUID.randomUUID();
        UUID eventId = UUID.randomUUID();
        handle(deviceId, "events", """
            {"schemaVersion":"2.0","deviceId":"%s","eventId":"%s","type":"TOUCH",
             "occurredAt":"2026-07-17T09:59:00Z",
             "localClip":{"state":"QUEUED","beforeMs":120000,"afterMs":0,"mergeWindowMs":0},
             "source":{"nodeId":"pi-gateway","component":"TOUCH_SENSOR"}}
            """.formatted(deviceId, eventId));

        verify(deviceEventService).accept(argThat(event ->
            event.id().equals(eventId)
                && event.deviceId().equals(deviceId)
                && event.type().equals("TOUCH")
                && event.confidence() == null
                && event.beforeMs() == 120000));
    }

    @Test
    void rejectsTouchEventFromNonSensorComponent() {
        UUID deviceId = UUID.randomUUID();
        handle(deviceId, "events", """
            {"schemaVersion":"2.0","deviceId":"%s","eventId":"%s","type":"TOUCH",
             "occurredAt":"2026-07-17T09:59:00Z",
             "localClip":{"state":"QUEUED","beforeMs":120000,"afterMs":0,"mergeWindowMs":0},
             "source":{"nodeId":"pi-gateway","component":"APP"}}
            """.formatted(deviceId, UUID.randomUUID()));

        verify(deviceEventService, never()).accept(org.mockito.ArgumentMatchers.any());
    }

    @Test
    void validatesAndPersistsClapEventFromYamnet() {
        UUID deviceId = UUID.randomUUID();
        UUID eventId = UUID.randomUUID();
        handle(deviceId, "events", """
            {"schemaVersion":"2.0","deviceId":"%s","eventId":"%s","type":"CLAP",
             "occurredAt":"2026-07-17T09:59:00Z","confidence":0.91,
             "localClip":{"state":"QUEUED","beforeMs":60000,"afterMs":60000,"mergeWindowMs":5000},
             "source":{"nodeId":"jetson","component":"YAMNET"}}
            """.formatted(deviceId, eventId));

        verify(deviceEventService).accept(argThat(event ->
            event.id().equals(eventId)
                && event.type().equals("CLAP")
                && event.confidence() == 0.91));
    }

    private void handle(UUID deviceId, String suffix, String json) {
        handler.handle(("local/wj/v2/devices/" + deviceId + "/" + suffix),
            json.getBytes(StandardCharsets.UTF_8));
    }
}
