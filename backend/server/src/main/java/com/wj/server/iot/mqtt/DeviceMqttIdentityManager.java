package com.wj.server.iot.mqtt;

import java.util.UUID;

public interface DeviceMqttIdentityManager {
    void create(UUID deviceId, String password);

    void rotate(UUID deviceId, String password);

    void revoke(UUID deviceId);
}
