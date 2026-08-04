package com.wj.server.stream.application;

import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import com.wj.server.config.MediaMtxProperties;
import com.wj.server.stream.domain.DeviceStreamRow;
import com.wj.server.stream.infrastructure.MediaMtxClient;
import com.wj.server.stream.persistence.StreamMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 유령 라이브 세션 대사(reconcile). 앱 heartbeat만으로는 "세션은 살아
 * 있는데 미디어가 흐르지 않는" 상태를 알 수 없다 — 서버가 아는 신호가
 * 기기 이벤트와 heartbeat뿐이었다. MediaMTX 관리 API에서 RUNNING 스트림의
 * 경로가 실제로 ready인지 확인하고, 연속 N회 미확인이면 스트림을 실패
 * 처리해 시청자에게 알리고 기기에 STOP을 보낸다.
 *
 * <p>API가 응답하지 않으면(UNKNOWN) 아무것도 실패 처리하지 않는다 —
 * 관측 도구의 장애가 정상 세션을 죽여서는 안 된다.
 */
@Component
public class StreamMediaReconcileWorker {
    private static final Logger log = LoggerFactory.getLogger(StreamMediaReconcileWorker.class);
    static final String FAILURE_CODE = "MEDIA_NOT_FLOWING";

    private final StreamMapper mapper;
    private final MediaMtxClient mediaMtx;
    private final StreamEventService events;
    private final StreamCommandPublisher publisher;
    private final MediaMtxProperties properties;
    private final Map<UUID, Integer> consecutiveMisses = new ConcurrentHashMap<>();

    public StreamMediaReconcileWorker(
        StreamMapper mapper,
        MediaMtxClient mediaMtx,
        StreamEventService events,
        StreamCommandPublisher publisher,
        MediaMtxProperties properties
    ) {
        this.mapper = mapper;
        this.mediaMtx = mediaMtx;
        this.events = events;
        this.publisher = publisher;
        this.properties = properties;
    }

    @Scheduled(fixedDelay = 15_000, initialDelay = 15_000)
    public void reconcile() {
        if (!properties.enabled()) {
            return;
        }
        var running = mapper.findRunningStreams();
        Set<UUID> runningIds = new HashSet<>();
        for (DeviceStreamRow stream : running) {
            runningIds.add(stream.id());
        }
        consecutiveMisses.keySet().retainAll(runningIds);

        for (DeviceStreamRow stream : running) {
            switch (mediaMtx.pathState(properties.pathPrefix() + "/" + stream.id())) {
                case READY -> consecutiveMisses.remove(stream.id());
                case UNKNOWN -> {
                    // 판단 불가 — 카운터를 늘리지도 지우지도 않는다.
                }
                case NOT_READY -> {
                    int misses = consecutiveMisses.merge(stream.id(), 1, Integer::sum);
                    if (misses >= properties.missesBeforeFailure()) {
                        consecutiveMisses.remove(stream.id());
                        log.warn("Ghost live stream detected streamId={} deviceId={} misses={}",
                            stream.id(), stream.deviceId(), misses);
                        events.failed(stream.deviceId(), stream.id(), FAILURE_CODE);
                        // 기기 쪽 릴레이가 살아 있을 수 있으니 정리를 시도한다.
                        // 실패해도 hard lease가 상한을 지킨다.
                        publisher.stop(stream.deviceId(), stream.id(), FAILURE_CODE);
                    }
                }
            }
        }
    }
}
