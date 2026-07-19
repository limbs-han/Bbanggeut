package com.wj.server.stream.application;

import java.time.Instant;
import java.util.UUID;

public interface StreamCommandPublisher {
    boolean start(UUID deviceId, UUID sessionId, UUID streamId, Instant hardExpiresAt);
    boolean extend(UUID deviceId, UUID streamId, Instant hardExpiresAt);
    boolean stop(UUID deviceId, UUID streamId, String reason);
}
