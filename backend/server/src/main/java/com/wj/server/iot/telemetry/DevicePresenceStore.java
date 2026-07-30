package com.wj.server.iot.telemetry;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.config.DevicePresenceProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * Redis-backed current device state.
 *
 * <p>Presence is operational state rather than durable business data. A key is
 * ONLINE while it exists and becomes OFFLINE automatically when its heartbeat
 * TTL expires, avoiding a database write for every MQTT heartbeat and a
 * database update just to mark stale rows offline.
 */
@Component
public class DevicePresenceStore {
    private static final Logger LOGGER = LoggerFactory.getLogger(DevicePresenceStore.class);
    private static final String KEY_PREFIX = "presence:device:";

    private final StringRedisTemplate redis;
    private final ObjectMapper objectMapper;
    private final DevicePresenceProperties properties;

    public DevicePresenceStore(
        StringRedisTemplate redis,
        ObjectMapper objectMapper,
        DevicePresenceProperties properties
    ) {
        this.redis = redis;
        this.objectMapper = objectMapper;
        this.properties = properties;
    }

    public boolean put(UUID deviceId, DevicePresenceSnapshot snapshot) {
        try {
            redis.opsForValue().set(
                key(deviceId), objectMapper.writeValueAsString(snapshot), properties.ttl());
            return true;
        } catch (DataAccessException | JsonProcessingException exception) {
            LOGGER.warn("Device presence store unavailable for deviceId={}", deviceId, exception);
            return false;
        }
    }

    /**
     * Establishes ONLINE presence without overwriting richer telemetry when a
     * heartbeat arrived before the retained MQTT ONLINE event.
     */
    public boolean putIfAbsent(UUID deviceId, DevicePresenceSnapshot snapshot) {
        try {
            redis.opsForValue().setIfAbsent(
                key(deviceId), objectMapper.writeValueAsString(snapshot), properties.ttl());
            return true;
        } catch (DataAccessException | JsonProcessingException exception) {
            LOGGER.warn("Device presence store unavailable for deviceId={}", deviceId, exception);
            return false;
        }
    }

    public boolean remove(UUID deviceId) {
        try {
            redis.delete(key(deviceId));
            return true;
        } catch (DataAccessException exception) {
            LOGGER.warn("Device presence store unavailable for deviceId={}", deviceId, exception);
            return false;
        }
    }

    public Lookup find(UUID deviceId) {
        try {
            return new Lookup(true, decode(redis.opsForValue().get(key(deviceId))));
        } catch (DataAccessException exception) {
            LOGGER.warn("Device presence lookup unavailable for deviceId={}", deviceId, exception);
            return new Lookup(false, null);
        }
    }

    public BatchLookup findAll(List<UUID> deviceIds) {
        if (deviceIds.isEmpty()) {
            return new BatchLookup(true, Map.of());
        }
        List<String> keys = deviceIds.stream().map(this::key).toList();
        try {
            List<String> values = redis.opsForValue().multiGet(keys);
            Map<UUID, DevicePresenceSnapshot> snapshots = new LinkedHashMap<>();
            if (values != null) {
                for (int index = 0; index < Math.min(deviceIds.size(), values.size()); index++) {
                    DevicePresenceSnapshot snapshot = decode(values.get(index));
                    if (snapshot != null) {
                        snapshots.put(deviceIds.get(index), snapshot);
                    }
                }
            }
            return new BatchLookup(true, snapshots);
        } catch (DataAccessException exception) {
            LOGGER.warn("Device presence batch lookup unavailable", exception);
            return new BatchLookup(false, Map.of());
        }
    }

    private DevicePresenceSnapshot decode(String value) {
        if (value == null) {
            return null;
        }
        try {
            return objectMapper.readValue(value, DevicePresenceSnapshot.class);
        } catch (JsonProcessingException exception) {
            LOGGER.warn("Ignored malformed device presence value", exception);
            return null;
        }
    }

    private String key(UUID deviceId) {
        return KEY_PREFIX + deviceId;
    }

    public record Lookup(boolean storeAvailable, DevicePresenceSnapshot snapshot) {
        public boolean online() {
            return snapshot != null;
        }
    }

    public record BatchLookup(
        boolean storeAvailable,
        Map<UUID, DevicePresenceSnapshot> snapshots
    ) {
    }
}
