package com.wj.server.stream.application;

import com.wj.server.config.StreamProperties;
import com.wj.server.stream.domain.DeviceStreamRow;
import com.wj.server.stream.persistence.StreamMapper;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

@Component
public class StreamLifecycleWorker {
    private final StreamMapper mapper;
    private final StreamCommandPublisher publisher;
    private final StreamProperties properties;

    public StreamLifecycleWorker(StreamMapper mapper, StreamCommandPublisher publisher, StreamProperties properties) {
        this.mapper = mapper;
        this.publisher = publisher;
        this.properties = properties;
    }

    @Scheduled(fixedDelay = 5000)
    @Transactional
    public void maintain() {
        mapper.expireStaleSessions();
        mapper.scheduleStopsWithoutViewers(properties.idleTimeout().toMillis());
        mapper.claimDueStop().ifPresent(this::stop);
    }

    private void stop(DeviceStreamRow stream) {
        if (publisher.stop(stream.deviceId(), stream.id(), "NO_ACTIVE_VIEWERS")) {
            mapper.completeStop(stream.id());
        } else {
            mapper.retryStop(stream.id());
        }
    }
}
