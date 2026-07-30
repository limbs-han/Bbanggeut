package com.wj.server.iot.telemetry;

import java.time.Clock;
import java.util.UUID;

import org.springframework.beans.factory.annotation.Autowired;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.stereotype.Service;

/**
 * Writes high-frequency current telemetry to Redis and falls back to the
 * durable device row when Redis cannot accept the heartbeat.
 */
@Service
public class DeviceTelemetryService {
    private static final Logger LOGGER = LoggerFactory.getLogger(DeviceTelemetryService.class);

    private final DevicePresenceStore presenceStore;
    private final DeviceTelemetryMapper telemetryMapper;
    private final Clock clock;

    @Autowired
    public DeviceTelemetryService(
        DevicePresenceStore presenceStore,
        DeviceTelemetryMapper telemetryMapper
    ) {
        this(presenceStore, telemetryMapper, Clock.systemUTC());
    }

    DeviceTelemetryService(
        DevicePresenceStore presenceStore,
        DeviceTelemetryMapper telemetryMapper,
        Clock clock
    ) {
        this.presenceStore = presenceStore;
        this.telemetryMapper = telemetryMapper;
        this.clock = clock;
    }

    public void recordHeartbeat(
        UUID deviceId,
        boolean recording,
        int uploadQueueDepth,
        Integer bufferSeconds,
        Integer personCount,
        String firmwareVersion
    ) {
        DevicePresenceSnapshot snapshot = new DevicePresenceSnapshot(
            clock.instant(), recording, uploadQueueDepth, bufferSeconds, personCount, firmwareVersion);
        if (!presenceStore.put(deviceId, snapshot)) {
            telemetryMapper.recordHeartbeat(
                deviceId, recording, uploadQueueDepth, bufferSeconds, personCount, firmwareVersion);
        }
    }

    public void recordConnectionState(UUID deviceId, boolean online, String firmwareVersion) {
        if (online) {
            presenceStore.putIfAbsent(deviceId, new DevicePresenceSnapshot(
                clock.instant(), false, 0, null, null, firmwareVersion));
        } else {
            presenceStore.remove(deviceId);
        }
        // Connection transitions and firmware changes are low-frequency and
        // useful as a durable fallback when Redis itself is unavailable. A
        // database outage must not prevent the live Redis state from changing.
        try {
            telemetryMapper.recordConnectionState(deviceId, online, firmwareVersion);
        } catch (DataAccessException exception) {
            LOGGER.warn(
                "Could not persist device connection fallback deviceId={}", deviceId, exception);
        }
    }
}
