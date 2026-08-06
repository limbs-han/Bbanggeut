package com.wj.server.stream.application;

import java.time.Instant;
import java.util.UUID;

import com.wj.server.stream.persistence.StreamMapper;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class StreamEventService {
    private final StreamMapper mapper;

    public StreamEventService(StreamMapper mapper) {
        this.mapper = mapper;
    }

    @Transactional
    public void ready(UUID deviceId, UUID streamId, Instant hardExpiresAt) {
        if (mapper.markStreamReady(deviceId, streamId, hardExpiresAt) == 1) {
            mapper.markSessionsReady(streamId);
        }
    }

    @Transactional
    public void failed(UUID deviceId, UUID streamId, String errorCode) {
        String safeCode = errorCode == null || errorCode.isBlank() ? "STREAM_ERROR" : errorCode.substring(0, Math.min(80, errorCode.length()));
        if (mapper.markStreamFailed(deviceId, streamId, safeCode) == 1) {
            mapper.markSessionsFailed(streamId, safeCode);
        }
    }

    /**
     * 미디어가 끊겼지만 아직 포기하지 않았다 — 시청자를 재연결 대기로 내린다.
     *
     * <p>스트림 행은 RUNNING으로 남긴다. 다른 상태로 옮기면 대사 워커가 그
     * 스트림을 더 이상 조회하지 않아, 미디어가 돌아와도 아무도 다시 READY로
     * 올려 주지 않는다.
     */
    @Transactional
    public void reconnecting(UUID streamId) {
        mapper.markSessionsReconnecting(streamId);
    }

    /** 유예 중이던 스트림에 미디어가 돌아왔다 — 기다리던 시청자를 다시 붙인다. */
    @Transactional
    public void resumed(UUID streamId) {
        mapper.markSessionsReady(streamId);
    }

    @Transactional
    public void stopped(UUID deviceId, UUID streamId) {
        if (mapper.markStreamStopped(deviceId, streamId) == 1) {
            mapper.closeSessionsForStoppedStream(streamId);
        }
    }
}
