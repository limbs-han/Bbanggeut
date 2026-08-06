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
 * 경로가 실제로 ready인지 확인한다.
 *
 * <p><b>끊김을 두 단계로 다룬다.</b> 예전에는 연속 2회(30초) 미확인이면
 * 곧바로 스트림을 실패 처리하고 기기에 STOP을 보냈다. 그런데 실제로 잡히는
 * 끊김의 대부분은 모바일망 송출이 몇 초 밀린 것이고, MediaMTX가 퍼블리셔를
 * 잘라낸 뒤 기기가 다시 붙는 동안 경로가 잠깐 비는 것이었다 — 곧 돌아올
 * 세션을 서버가 확인사살하고 있었다. 이제 첫 문턱에서는 시청자를 재연결
 * 대기(PENDING)로만 내리고, {@code missesBeforeGiveUp}까지 미디어가 돌아오지
 * 않을 때 실패로 확정한다. 유예 안에 돌아오면 시청자를 다시 READY로 붙인다.
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
                case READY -> {
                    // 유예 중이었다면 기다리던 시청자를 다시 붙인다. 카운터가
                    // 없었다면 애초에 끊긴 적이 없으므로 아무것도 하지 않는다 —
                    // 15초마다 멀쩡한 세션에 UPDATE를 날릴 이유가 없다.
                    Integer misses = consecutiveMisses.remove(stream.id());
                    if (misses != null && misses >= properties.missesBeforeFailure()) {
                        log.info("Live media resumed streamId={} deviceId={} afterMisses={}",
                            stream.id(), stream.deviceId(), misses);
                        events.resumed(stream.id());
                    }
                }
                case UNKNOWN -> {
                    // 판단 불가 — 카운터를 늘리지도 지우지도 않는다.
                }
                case NOT_READY -> {
                    int misses = consecutiveMisses.merge(stream.id(), 1, Integer::sum);
                    if (misses >= properties.missesBeforeGiveUp()) {
                        consecutiveMisses.remove(stream.id());
                        log.warn("Ghost live stream detected streamId={} deviceId={} misses={}",
                            stream.id(), stream.deviceId(), misses);
                        events.failed(stream.deviceId(), stream.id(), FAILURE_CODE);
                        // 기기 쪽 릴레이가 살아 있을 수 있으니 정리를 시도한다.
                        // 실패해도 hard lease가 상한을 지킨다.
                        publisher.stop(stream.deviceId(), stream.id(), FAILURE_CODE);
                    } else if (misses == properties.missesBeforeFailure()) {
                        // 문턱을 넘는 순간에만 내린다. 매 주기 반복하면 같은
                        // UPDATE가 유예 내내 나가고, 유예 중 사용자가 다시
                        // 붙어 READY가 된 세션을 뒤늦게 또 내려 버린다.
                        log.warn("Live media stalled, waiting for reconnect "
                                + "streamId={} deviceId={} misses={} giveUpAt={}",
                            stream.id(), stream.deviceId(), misses,
                            properties.missesBeforeGiveUp());
                        events.reconnecting(stream.id());
                    }
                }
            }
        }
    }
}
