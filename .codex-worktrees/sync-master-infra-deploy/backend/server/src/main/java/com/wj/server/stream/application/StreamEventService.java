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

    @Transactional
    public void stopped(UUID deviceId, UUID streamId) {
        if (mapper.markStreamStopped(deviceId, streamId) == 1) {
            mapper.closeSessionsForStoppedStream(streamId);
        }
    }
}
