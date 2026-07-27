package com.wj.server.iot.mqtt;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.wj.server.common.api.ApiException;
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
import org.springframework.http.HttpStatus;

@Component
public class PahoMqttGateway implements StreamCommandPublisher, DeviceMqttIdentityManager, MqttCallbackExtended {
    private static final Logger log = LoggerFactory.getLogger(PahoMqttGateway.class);
    private static final String DYNSEC_REQUEST_TOPIC = "$CONTROL/dynamic-security/v1";
    private static final String DYNSEC_RESPONSE_TOPIC = "$CONTROL/dynamic-security/v1/response";
    private static final String TOPIC_VERSION = "v2";
    private static final String LEGACY_TOPIC_VERSION = "v1";
    private static final List<String> DEVICE_PUBLISH_SUFFIXES = List.of(
        "status", "heartbeat", "registration", "events", "stream/events", "commands/ack");
    private final MqttProperties properties;
    private final ObjectMapper objectMapper;
    private final MqttInboundHandler inboundHandler;
    private MqttClient client;
    private volatile CompletableFuture<JsonNode> pendingDynsecResponse;

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
            if (properties.brokerUrl().startsWith("ssl://")) {
                options.setSocketFactory(mqttSslContext().getSocketFactory());
                options.setHttpsHostnameVerificationEnabled(true);
            }
            client.connect(options);
        } catch (Exception exception) {
            log.warn("MQTT broker connection unavailable: {}", exception.getClass().getSimpleName());
        }
    }

    private SSLContext mqttSslContext() throws Exception {
        if (properties.tlsCaPath() == null || properties.tlsCaPath().isBlank()) {
            return SSLContext.getDefault();
        }
        CertificateFactory certificates = CertificateFactory.getInstance("X.509");
        KeyStore trustStore = KeyStore.getInstance(KeyStore.getDefaultType());
        trustStore.load(null, null);
        try (InputStream input = Files.newInputStream(Path.of(properties.tlsCaPath()))) {
            trustStore.setCertificateEntry("mqtt-ca", certificates.generateCertificate(input));
        }
        TrustManagerFactory trustManagers = TrustManagerFactory.getInstance(
            TrustManagerFactory.getDefaultAlgorithm());
        trustManagers.init(trustStore);
        SSLContext context = SSLContext.getInstance("TLSv1.3");
        context.init(null, trustManagers.getTrustManagers(), null);
        return context;
    }

    @Override
    public void connectComplete(boolean reconnect, String serverURI) {
        try {
            String base = baseTopic() + "/devices/+/";
            client.subscribe(new String[] {
                base + "status", base + "heartbeat", base + "registration", base + "stream/events",
                base + "events", base + "commands/ack", DYNSEC_RESPONSE_TOPIC
            }, new int[] {1, 0, 1, 1, 1, 1, 1});
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
        if (DYNSEC_RESPONSE_TOPIC.equals(topic)) {
            completeDynsecRequest(message.getPayload());
            return;
        }
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

    @Override
    public void create(UUID deviceId, String password) {
        String username = deviceId.toString();
        String role = "device-" + deviceId;
        List<ObjectNode> commands = new ArrayList<>();
        commands.add(command("createClient")
            .put("username", username).put("password", password).put("clientid", username));
        commands.add(command("createRole").put("rolename", role));
        for (String suffix : DEVICE_PUBLISH_SUFFIXES) {
            commands.add(acl(role, "publishClientSend", deviceTopic(deviceId, suffix)));
        }
        commands.add(acl(role, "subscribeLiteral", deviceTopic(deviceId, "commands")));
        commands.add(acl(role, "publishClientReceive", deviceTopic(deviceId, "commands")));
        commands.add(command("addClientRole")
            .put("username", username).put("rolename", role).put("priority", 100));
        try {
            executeDynsec(commands, true);
        } catch (RuntimeException exception) {
            try {
                executeDynsec(List.of(
                    command("deleteClient").put("username", username),
                    command("deleteRole").put("rolename", role)
                ), false);
            } catch (RuntimeException cleanupFailure) {
                log.warn("MQTT identity cleanup failed for device {}", deviceId);
            }
            throw exception;
        }
    }

    @Override
    public void rotate(UUID deviceId, String password) {
        if (!clientExists(deviceId)) {
            create(deviceId, password);
            return;
        }
        executeDynsec(List.of(
            command("modifyClient")
                .put("username", deviceId.toString())
                .put("password", password)
                .put("clientid", deviceId.toString()),
            command("enableClient").put("username", deviceId.toString())
        ), true);
        migrateTopicAcl(deviceId);
    }

    @Override
    public void migrateTopicAcl(UUID deviceId) {
        if (!clientExists(deviceId)) {
            return;
        }
        String role = "device-" + deviceId;
        if (!roleExists(role)) {
            executeDynsec(List.of(command("createRole").put("rolename", role)), true);
        }

        List<ObjectNode> removals = new ArrayList<>();
        for (String version : List.of(LEGACY_TOPIC_VERSION, TOPIC_VERSION)) {
            for (String suffix : DEVICE_PUBLISH_SUFFIXES) {
                removals.add(removeAcl(
                    role, "publishClientSend", deviceTopic(version, deviceId, suffix)));
            }
            removals.add(removeAcl(
                role, "subscribeLiteral", deviceTopic(version, deviceId, "commands")));
            removals.add(removeAcl(
                role, "publishClientReceive", deviceTopic(version, deviceId, "commands")));
        }
        executeDynsec(removals, false);

        List<ObjectNode> additions = new ArrayList<>();
        for (String suffix : DEVICE_PUBLISH_SUFFIXES) {
            additions.add(acl(role, "publishClientSend", deviceTopic(deviceId, suffix)));
        }
        additions.add(acl(role, "subscribeLiteral", deviceTopic(deviceId, "commands")));
        additions.add(acl(role, "publishClientReceive", deviceTopic(deviceId, "commands")));
        executeDynsec(additions, true);
        executeDynsec(List.of(command("addClientRole")
            .put("username", deviceId.toString())
            .put("rolename", role)
            .put("priority", 100)), false);
    }

    private boolean roleExists(String role) {
        JsonNode response = executeDynsec(List.of(
            command("getRole").put("rolename", role)
        ), false);
        JsonNode first = response.path("responses").path(0);
        return first.isObject() && !first.hasNonNull("error");
    }

    private boolean clientExists(UUID deviceId) {
        JsonNode response = executeDynsec(List.of(
            command("getClient").put("username", deviceId.toString())
        ), false);
        JsonNode first = response.path("responses").path(0);
        return first.isObject() && !first.hasNonNull("error");
    }

    @Override
    public void revoke(UUID deviceId) {
        if (!clientExists(deviceId)) {
            return;
        }
        executeDynsec(List.of(command("disableClient").put("username", deviceId.toString())), true);
    }

    private ObjectNode command(String name) {
        return objectMapper.createObjectNode().put("command", name);
    }

    private ObjectNode acl(String role, String type, String topic) {
        return command("addRoleACL")
            .put("rolename", role)
            .put("acltype", type)
            .put("topic", topic)
            .put("priority", 100)
            .put("allow", true);
    }

    private ObjectNode removeAcl(String role, String type, String topic) {
        return command("removeRoleACL")
            .put("rolename", role)
            .put("acltype", type)
            .put("topic", topic);
    }

    private String deviceTopic(UUID deviceId, String suffix) {
        return deviceTopic(TOPIC_VERSION, deviceId, suffix);
    }

    private String deviceTopic(String version, UUID deviceId, String suffix) {
        return properties.environment() + "/wj/" + version + "/devices/" + deviceId + "/" + suffix;
    }

    private synchronized JsonNode executeDynsec(List<ObjectNode> commands, boolean failOnCommandError) {
        connectIfNeeded();
        if (client == null || !client.isConnected()) {
            throw mqttAdminUnavailable();
        }
        try {
            ObjectNode request = objectMapper.createObjectNode();
            request.putArray("commands").addAll(commands);
            pendingDynsecResponse = new CompletableFuture<>();
            MqttMessage message = new MqttMessage(objectMapper.writeValueAsBytes(request));
            message.setQos(1);
            client.publish(DYNSEC_REQUEST_TOPIC, message);
            JsonNode response = pendingDynsecResponse.get(5, TimeUnit.SECONDS);
            for (JsonNode item : response.path("responses")) {
                if (failOnCommandError && item.hasNonNull("error")) {
                    throw new ApiException(
                        HttpStatus.SERVICE_UNAVAILABLE,
                        "MQTT_IDENTITY_UPDATE_FAILED",
                        "MQTT device identity update was rejected by the broker.");
                }
            }
            return response;
        } catch (TimeoutException exception) {
            throw mqttAdminUnavailable();
        } catch (ApiException exception) {
            throw exception;
        } catch (Exception exception) {
            throw mqttAdminUnavailable();
        } finally {
            pendingDynsecResponse = null;
        }
    }

    private void completeDynsecRequest(byte[] payload) {
        CompletableFuture<JsonNode> pending = pendingDynsecResponse;
        if (pending == null) {
            return;
        }
        try {
            pending.complete(objectMapper.readTree(payload));
        } catch (Exception exception) {
            pending.completeExceptionally(exception);
        }
    }

    private ApiException mqttAdminUnavailable() {
        return new ApiException(
            HttpStatus.SERVICE_UNAVAILABLE,
            "MQTT_IDENTITY_SERVICE_UNAVAILABLE",
            "MQTT device identity service is unavailable.");
    }

    private synchronized boolean publish(UUID deviceId, String type, Map<String, Object> payload) {
        connectIfNeeded();
        if (client == null || !client.isConnected()) {
            return false;
        }
        Instant issuedAt = Instant.now();
        Map<String, Object> command = new LinkedHashMap<>();
        command.put("schemaVersion", "2.0");
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
        return properties.environment() + "/wj/" + TOPIC_VERSION;
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
