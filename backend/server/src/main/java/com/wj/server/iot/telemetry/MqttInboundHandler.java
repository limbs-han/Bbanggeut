package com.wj.server.iot.telemetry;

import java.time.Clock;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.UUID;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.iot.event.DeviceEvent;
import com.wj.server.iot.event.DeviceEventService;
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
    private final DeviceEventService deviceEventService;
    private final Clock clock;

    @Autowired
    public MqttInboundHandler(
        ObjectMapper objectMapper,
        DeviceTelemetryMapper telemetryMapper,
        StreamEventService streamEventService,
        DeviceEventService deviceEventService
    ) {
        this(objectMapper, telemetryMapper, streamEventService, deviceEventService, Clock.systemUTC());
    }

    MqttInboundHandler(
        ObjectMapper objectMapper,
        DeviceTelemetryMapper telemetryMapper,
        StreamEventService streamEventService,
        DeviceEventService deviceEventService,
        Clock clock
    ) {
        this.objectMapper = objectMapper;
        this.telemetryMapper = telemetryMapper;
        this.streamEventService = streamEventService;
        this.deviceEventService = deviceEventService;
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
            if (!"2.0".equals(text(body, "schemaVersion"))
                || !topicDeviceId.equals(UUID.fromString(text(body, "deviceId")))) {
                return;
            }

            String suffix = String.join("/", java.util.Arrays.copyOfRange(parts, 5, parts.length));
            switch (suffix) {
                case "heartbeat" -> heartbeat(topicDeviceId, body);
                case "registration" -> registration(topicDeviceId, body);
                case "status" -> status(topicDeviceId, body);
                case "stream/events" -> streamEvent(topicDeviceId, body);
                case "events" -> detectionEvent(topicDeviceId, body);
                case "commands/ack" -> commandAck(topicDeviceId, body);
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
        Integer personCount = body.hasNonNull("personCount")
            ? nonNegativeInt(body, "personCount", 0) : null;
        String firmware = boundedText(body, "firmwareVersion", 40);
        telemetryMapper.recordHeartbeat(deviceId, body.path("recording").asBoolean(false),
            queueDepth, bufferSeconds, personCount, firmware);
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

    private void detectionEvent(UUID deviceId, JsonNode body) {
        UUID eventId = UUID.fromString(text(body, "eventId"));
        String type = text(body, "type");
        if (!java.util.Set.of("LAUGHTER", "WAKE_WORD", "TOUCH", "MANUAL").contains(type)) {
            throw new IllegalArgumentException("Unsupported event type");
        }
        Instant occurredAt = Instant.parse(text(body, "occurredAt"));
        if (occurredAt.isAfter(clock.instant().plus(5, ChronoUnit.MINUTES))) {
            throw new IllegalArgumentException("Event time is too far in the future");
        }
        JsonNode confidence = body.get("confidence");
        if (confidence != null && (!confidence.isNumber()
            || confidence.doubleValue() < 0.0 || confidence.doubleValue() > 1.0)) {
            throw new IllegalArgumentException("Invalid confidence");
        }
        if (java.util.Set.of("LAUGHTER", "WAKE_WORD").contains(type)
            && (confidence == null || confidence.isNull())) {
            throw new IllegalArgumentException("AI events require confidence");
        }
        if (java.util.Set.of("TOUCH", "MANUAL").contains(type)
            && confidence != null && !confidence.isNull()) {
            throw new IllegalArgumentException("Physical/manual events must not contain confidence");
        }

        JsonNode localClip = requiredObject(body, "localClip");
        String clipState = text(localClip, "state");
        if (!java.util.Set.of("SEGMENTS_LOCKED", "GENERATING", "QUEUED", "FAILED")
            .contains(clipState)) {
            throw new IllegalArgumentException("Invalid local clip state");
        }
        int beforeMs = boundedNonNegativeInt(localClip, "beforeMs", 3_600_000);
        int afterMs = boundedNonNegativeInt(localClip, "afterMs", 3_600_000);
        int mergeWindowMs = boundedNonNegativeInt(localClip, "mergeWindowMs", 600_000);

        JsonNode source = requiredObject(body, "source");
        String nodeId = requiredBoundedText(source, "nodeId", 80);
        String component = requiredBoundedText(source, "component", 40);
        if (!java.util.Set.of(
            "YAMNET", "KEYWORD_SPOTTING", "TOUCH_SENSOR", "APP", "LOCAL_CONTROL"
        ).contains(component)) {
            throw new IllegalArgumentException("Invalid source component");
        }
        if ("TOUCH".equals(type) && !"TOUCH_SENSOR".equals(component)) {
            throw new IllegalArgumentException("TOUCH events require TOUCH_SENSOR");
        }
        String modelVersion = boundedText(source, "modelVersion", 80);

        deviceEventService.accept(new DeviceEvent(
            eventId, deviceId, type, occurredAt,
            confidence == null || confidence.isNull() ? null : confidence.doubleValue(),
            clipState, beforeMs, afterMs, mergeWindowMs, nodeId, component, modelVersion));
        log.info("Accepted device event {} ({}) from {}", eventId, type, deviceId);
    }

    private void commandAck(UUID deviceId, JsonNode body) {
        UUID requestId = UUID.fromString(text(body, "requestId"));
        String status = text(body, "status");
        if (!java.util.Set.of("ACCEPTED", "SUCCEEDED", "FAILED", "REJECTED", "EXPIRED")
            .contains(status)) {
            throw new IllegalArgumentException("Invalid command status");
        }
        log.debug("Device {} acknowledged command {} as {}", deviceId, requestId, status);
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

    private JsonNode requiredObject(JsonNode body, String field) {
        JsonNode node = body.get(field);
        if (node == null || !node.isObject()) {
            throw new IllegalArgumentException("Missing " + field);
        }
        return node;
    }

    private String requiredBoundedText(JsonNode body, String field, int maxLength) {
        String value = text(body, field);
        if (value.length() > maxLength) {
            throw new IllegalArgumentException("Invalid " + field);
        }
        return value;
    }

    private int boundedNonNegativeInt(JsonNode body, String field, int maxValue) {
        int value = nonNegativeInt(body, field, -1);
        if (value < 0 || value > maxValue) {
            throw new IllegalArgumentException("Invalid " + field);
        }
        return value;
    }
}
