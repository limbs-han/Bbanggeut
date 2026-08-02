package com.wj.server.stream.application;

import com.wj.server.config.StreamProperties;
import com.wj.server.stream.domain.DeviceStreamRow;
import com.wj.server.stream.domain.TalkbackRow;
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
        releaseExpiredTalkbacks();
    }

    /**
     * 앱이 heartbeat 없이 사라지면 발화 권한이 남는다. 회수하지 않으면 기기가
     * 마이크를 계속 닫아둔 채 다른 구성원도 말할 수 없는 상태로 굳는다.
     */
    private void releaseExpiredTalkbacks() {
        for (TalkbackRow talkback : mapper.claimExpiredTalkbacks()) {
            publisher.stopTalkback(talkback.deviceId(), talkback.streamId(), "TALKBACK_EXPIRED");
        }
    }

    private void stop(DeviceStreamRow stream) {
        if (publisher.stop(stream.deviceId(), stream.id(), "NO_ACTIVE_VIEWERS")) {
            mapper.completeStop(stream.id());
        } else {
            mapper.retryStop(stream.id());
        }
    }
}
