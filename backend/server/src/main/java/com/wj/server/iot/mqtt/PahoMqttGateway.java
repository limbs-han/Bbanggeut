package com.wj.server.iot.mqtt;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.config.MqttProperties;
import com.wj.server.iot.telemetry.MqttInboundHandler;
import com.wj.server.stream.application.StreamCommandPublisher;
import jakarta.annotation.PreDestroy;
import org.eclipse.paho.client.mqttv3.IMqttDeliveryToken;
import org.eclipse.paho.client.mqttv3.MqttCallbackExtended;
import org.eclipse.paho.client.mqttv3.MqttClient;
import org.eclipse.paho.client.mqttv3.MqttConnectOptions;
import org.eclipse.paho.client.mqttv3.MqttException;
import org.eclipse.paho.client.mqttv3.MqttMessage;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
public class PahoMqttGateway implements StreamCommandPublisher, MqttCallbackExtended {
    private static final Logger log = LoggerFactory.getLogger(PahoMqttGateway.class);
    private final MqttProperties properties;
    private final ObjectMapper objectMapper;
    private final MqttInboundHandler inboundHandler;
    private MqttClient client;

    public PahoMqttGateway(
        MqttProperties properties,
        ObjectMapper objectMapper,
        MqttInboundHandler inboundHandler
    ) {
        this.properties = properties;
        this.objectMapper = objectMapper;
        this.inboundHandler = inboundHandler;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void start() {
        connectIfNeeded();
    }

    @Scheduled(fixedDelay = 10_000, initialDelay = 10_000)
    public void reconnect() {
        connectIfNeeded();
    }

    private synchronized void connectIfNeeded() {
        try {
            if (client != null && client.isConnected()) {
                return;
            }
            if (client == null) {
                client = new MqttClient(properties.brokerUrl(), properties.clientId(), new MemoryPersistence());
                client.setCallback(this);
            }
            MqttConnectOptions options = new MqttConnectOptions();
            options.setAutomaticReconnect(true);
            options.setCleanSession(true);
            options.setConnectionTimeout(5);
            options.setKeepAliveInterval(30);
            if (properties.username() != null && !properties.username().isBlank()) {
                options.setUserName(properties.username());
                options.setPassword(properties.password() == null ? new char[0] : properties.password().toCharArray());
            }
            client.connect(options);
        } catch (MqttException exception) {
            log.warn("MQTT broker connection unavailable: {}", exception.getReasonCode());
        }
    }

    @Override
    public void connectComplete(boolean reconnect, String serverURI) {
        try {
            String base = baseTopic() + "/devices/+/";
            client.subscribe(new String[] {
                base + "status", base + "heartbeat", base + "registration", base + "stream/events"
            }, new int[] {1, 0, 1, 1});
            log.info("MQTT subscriptions active ({})", reconnect ? "reconnected" : "connected");
        } catch (MqttException exception) {
            log.warn("MQTT subscription failed: {}", exception.getReasonCode());
        }
    }

    @Override
    public void connectionLost(Throwable cause) {
        log.warn("MQTT connection lost; automatic reconnect is enabled");
    }

    @Override
    public void messageArrived(String topic, MqttMessage message) {
        inboundHandler.handle(topic, message.getPayload());
    }

    @Override
    public void deliveryComplete(IMqttDeliveryToken token) {
    }

    @Override
    public boolean start(UUID deviceId, UUID sessionId, UUID streamId, Instant hardExpiresAt) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("sessionId", sessionId);
        payload.put("streamId", streamId);
        payload.put("profile", "LIVE_720P_H264_AAC");
        payload.put("segmentDurationSeconds", 2);
        payload.put("hardExpiresAt", hardExpiresAt);
        return publish(deviceId, "START_STREAM", payload);
    }

    @Override
    public boolean extend(UUID deviceId, UUID streamId, Instant hardExpiresAt) {
        return publish(deviceId, "EXTEND_STREAM", Map.of(
            "streamId", streamId, "hardExpiresAt", hardExpiresAt));
    }

    @Override
    public boolean stop(UUID deviceId, UUID streamId, String reason) {
        return publish(deviceId, "STOP_STREAM", Map.of("streamId", streamId, "reason", reason));
    }

    private synchronized boolean publish(UUID deviceId, String type, Map<String, Object> payload) {
        connectIfNeeded();
        if (client == null || !client.isConnected()) {
            return false;
        }
        Instant issuedAt = Instant.now();
        Map<String, Object> command = new LinkedHashMap<>();
        command.put("schemaVersion", "1.0");
        command.put("requestId", UUID.randomUUID());
        command.put("deviceId", deviceId);
        command.put("type", type);
        command.put("issuedAt", issuedAt);
        command.put("expiresAt", issuedAt.plus(15, ChronoUnit.SECONDS));
        command.put("payload", payload);
        try {
            byte[] bytes = objectMapper.writeValueAsString(command).getBytes(StandardCharsets.UTF_8);
            MqttMessage message = new MqttMessage(bytes);
            message.setQos(1);
            message.setRetained(false);
            client.publish(baseTopic() + "/devices/" + deviceId + "/commands", message);
            return true;
        } catch (MqttException | JsonProcessingException exception) {
            log.warn("MQTT command publish failed for device {}: {}", deviceId, exception.getClass().getSimpleName());
            return false;
        }
    }

    private String baseTopic() {
        return properties.environment() + "/wj/v1";
    }

    @PreDestroy
    public synchronized void close() {
        if (client == null) {
            return;
        }
        try {
            if (client.isConnected()) {
                client.disconnect(1_000);
            }
            client.close();
        } catch (MqttException exception) {
            log.debug("MQTT client shutdown was incomplete", exception);
        }
    }
}
