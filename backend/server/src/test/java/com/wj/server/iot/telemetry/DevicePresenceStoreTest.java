package com.wj.server.iot.telemetry;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.wj.server.config.DevicePresenceProperties;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

@ExtendWith(MockitoExtension.class)
class DevicePresenceStoreTest {
    private static final Duration TTL = Duration.ofSeconds(90);

    @Mock private StringRedisTemplate redis;
    @Mock private ValueOperations<String, String> values;
    private ObjectMapper objectMapper;
    private DevicePresenceStore store;

    @BeforeEach
    void setUp() {
        objectMapper = new ObjectMapper().findAndRegisterModules();
        when(redis.opsForValue()).thenReturn(values);
        store = new DevicePresenceStore(
            redis, objectMapper, new DevicePresenceProperties(TTL));
    }

    @Test
    void writesSnapshotWithPresenceTtl() throws Exception {
        UUID deviceId = UUID.randomUUID();
        DevicePresenceSnapshot snapshot = snapshot("2026-07-30T01:00:00Z");

        assertThat(store.put(deviceId, snapshot)).isTrue();

        ArgumentCaptor<String> json = ArgumentCaptor.forClass(String.class);
        verify(values).set(
            org.mockito.ArgumentMatchers.eq("presence:device:" + deviceId),
            json.capture(),
            org.mockito.ArgumentMatchers.eq(TTL));
        assertThat(objectMapper.readValue(json.getValue(), DevicePresenceSnapshot.class))
            .isEqualTo(snapshot);
    }

    @Test
    void missingKeyMeansOfflineWhileRedisIsAvailable() {
        UUID deviceId = UUID.randomUUID();
        when(values.get(anyString())).thenReturn(null);

        DevicePresenceStore.Lookup result = store.find(deviceId);

        assertThat(result.storeAvailable()).isTrue();
        assertThat(result.online()).isFalse();
    }

    @Test
    void onlineTransitionDoesNotOverwriteAnExistingHeartbeat() {
        UUID deviceId = UUID.randomUUID();
        DevicePresenceSnapshot placeholder = snapshot("2026-07-30T01:00:00Z");

        assertThat(store.putIfAbsent(deviceId, placeholder)).isTrue();

        verify(values).setIfAbsent(
            org.mockito.ArgumentMatchers.eq("presence:device:" + deviceId),
            org.mockito.ArgumentMatchers.anyString(),
            org.mockito.ArgumentMatchers.eq(TTL));
    }

    @Test
    void connectionFailureIsDistinguishedFromAnOfflineDevice() {
        UUID deviceId = UUID.randomUUID();
        when(values.get(anyString()))
            .thenThrow(new RedisConnectionFailureException("unavailable"));

        DevicePresenceStore.Lookup result = store.find(deviceId);

        assertThat(result.storeAvailable()).isFalse();
        assertThat(result.snapshot()).isNull();
    }

    @Test
    void batchLookupKeepsDeviceAndValueAlignment() throws Exception {
        UUID online = UUID.randomUUID();
        UUID offline = UUID.randomUUID();
        DevicePresenceSnapshot snapshot = snapshot("2026-07-30T01:00:00Z");
        when(values.multiGet(List.of(
            "presence:device:" + online,
            "presence:device:" + offline)))
            .thenReturn(java.util.Arrays.asList(
                objectMapper.writeValueAsString(snapshot), null));

        DevicePresenceStore.BatchLookup result = store.findAll(List.of(online, offline));

        assertThat(result.storeAvailable()).isTrue();
        assertThat(result.snapshots()).containsOnlyKeys(online);
        assertThat(result.snapshots().get(online)).isEqualTo(snapshot);
    }

    private DevicePresenceSnapshot snapshot(String instant) {
        return new DevicePresenceSnapshot(
            Instant.parse(instant), true, 2, 120, 3, "0.4.0");
    }
}
