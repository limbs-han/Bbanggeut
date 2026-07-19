package com.wj.server.iot.telemetry;

import java.time.Clock;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.UUID;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.stream.application.StreamEventService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

@Component
public class MqttInboundHandler {
    private static final Logger log = LoggerFactory.getLogger(MqttInboundHandler.class);
    private final ObjectMapper objectMapper;
    private final DeviceTelemetryMapper telemetryMapper;
    private final StreamEventService streamEventService;
    private final Clock clock;

    @Autowired
    public MqttInboundHandler(
        ObjectMapper objectMapper,
        DeviceTelemetryMapper telemetryMapper,
        StreamEventService streamEventService
    ) {
        this(objectMapper, telemetryMapper, streamEventService, Clock.systemUTC());
    }

    MqttInboundHandler(
        ObjectMapper objectMapper,
        DeviceTelemetryMapper telemetryMapper,
        StreamEventService streamEventService,
        Clock clock
    ) {
        this.objectMapper = objectMapper;
        this.telemetryMapper = telemetryMapper;
        this.streamEventService = streamEventService;
        this.clock = clock;
    }

    public void handle(String topic, byte[] payload) {
        try {
            String[] parts = topic.split("/");
            if (parts.length < 6 || !"devices".equals(parts[3])) {
                return;
            }
            UUID topicDeviceId = UUID.fromString(parts[4]);
            JsonNode body = objectMapper.readTree(payload);
            if (!"1.0".equals(text(body, "schemaVersion"))
                || !topicDeviceId.equals(UUID.fromString(text(body, "deviceId")))) {
                return;
            }

            String suffix = String.join("/", java.util.Arrays.copyOfRange(parts, 5, parts.length));
            switch (suffix) {
                case "heartbeat" -> heartbeat(topicDeviceId, body);
                case "registration" -> registration(topicDeviceId, body);
                case "status" -> status(topicDeviceId, body);
                case "stream/events" -> streamEvent(topicDeviceId, body);
                default -> { }
            }
        } catch (RuntimeException | java.io.IOException exception) {
            log.warn("Ignored invalid MQTT message on topic {}: {}", topic, exception.getClass().getSimpleName());
        }
    }

    private void heartbeat(UUID deviceId, JsonNode body) {
        int queueDepth = nonNegativeInt(body, "uploadQueueDepth", 0);
        Integer bufferSeconds = body.hasNonNull("bufferSeconds")
            ? nonNegativeInt(body, "bufferSeconds", 0) : null;
        String firmware = boundedText(body, "firmwareVersion", 40);
        telemetryMapper.recordHeartbeat(deviceId, body.path("recording").asBoolean(false),
            queueDepth, bufferSeconds, firmware);
    }

    private void registration(UUID deviceId, JsonNode body) {
        if ("DISABLED".equals(text(body, "mode"))) {
            telemetryMapper.updateRegistrationMode(deviceId, null);
            return;
        }
        if (!"ENABLED".equals(text(body, "mode"))) {
            return;
        }
        Instant now = clock.instant();
        Instant expiresAt = Instant.parse(text(body, "expiresAt"));
        if (expiresAt.isAfter(now) && !expiresAt.isAfter(now.plus(5, ChronoUnit.MINUTES))) {
            telemetryMapper.updateRegistrationMode(deviceId, expiresAt);
        }
    }

    private void status(UUID deviceId, JsonNode body) {
        String state = text(body, "state");
        if ("ONLINE".equals(state) || "OFFLINE".equals(state)) {
            telemetryMapper.recordConnectionState(deviceId, "ONLINE".equals(state),
                boundedText(body, "firmwareVersion", 40));
        }
    }

    private void streamEvent(UUID deviceId, JsonNode body) {
        UUID streamId = UUID.fromString(text(body, "streamId"));
        String type = text(body, "type");
        switch (type) {
            case "STREAM_READY" -> streamEventService.ready(deviceId, streamId,
                Instant.parse(text(body, "hardExpiresAt")));
            case "STREAM_ERROR", "STREAM_HARD_EXPIRED" ->
                streamEventService.failed(deviceId, streamId, text(body, "errorCode"));
            case "STREAM_STOPPED" -> streamEventService.stopped(deviceId, streamId);
            default -> { }
        }
    }

    private String text(JsonNode body, String field) {
        JsonNode node = body.get(field);
        if (node == null || !node.isTextual() || node.textValue().isBlank()) {
            throw new IllegalArgumentException("Missing " + field);
        }
        return node.textValue();
    }

    private String boundedText(JsonNode body, String field, int maxLength) {
        JsonNode node = body.get(field);
        if (node == null || node.isNull()) {
            return null;
        }
        if (!node.isTextual() || node.textValue().length() > maxLength) {
            throw new IllegalArgumentException("Invalid " + field);
        }
        return node.textValue();
    }

    private int nonNegativeInt(JsonNode body, String field, int defaultValue) {
        JsonNode node = body.get(field);
        if (node == null || node.isNull()) {
            return defaultValue;
        }
        if (!node.canConvertToInt() || node.intValue() < 0) {
            throw new IllegalArgumentException("Invalid " + field);
        }
        return node.intValue();
    }
}
