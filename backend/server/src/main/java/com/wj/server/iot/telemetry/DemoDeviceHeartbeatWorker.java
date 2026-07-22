package com.wj.server.iot.telemetry;

import java.util.UUID;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Keeps the seeded camera realistic and online while the explicit demo profile is enabled. */
@Component
@ConditionalOnProperty(name = "app.demo.enabled", havingValue = "true")
public class DemoDeviceHeartbeatWorker {
    static final UUID DEMO_DEVICE_ID = UUID.fromString("10000000-0000-0000-0000-000000000001");

    private final DeviceTelemetryMapper telemetryMapper;

    public DemoDeviceHeartbeatWorker(DeviceTelemetryMapper telemetryMapper) {
        this.telemetryMapper = telemetryMapper;
    }

    @Scheduled(initialDelay = 0, fixedDelay = 30_000)
    public void heartbeat() {
        telemetryMapper.recordHeartbeat(DEMO_DEVICE_ID, true, 0, 30, 2, "demo-1.0.0");
    }
}
