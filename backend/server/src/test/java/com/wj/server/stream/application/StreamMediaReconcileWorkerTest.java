package com.wj.server.stream.application;

import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.wj.server.config.MediaMtxProperties;
import com.wj.server.stream.domain.DeviceStreamRow;
import com.wj.server.stream.infrastructure.MediaMtxClient;
import com.wj.server.stream.infrastructure.MediaMtxClient.PathState;
import com.wj.server.stream.persistence.StreamMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class StreamMediaReconcileWorkerTest {
    private static final MediaMtxProperties ENABLED =
        new MediaMtxProperties("http://127.0.0.1:9997", "live", 2);

    @Mock
    private StreamMapper mapper;
    @Mock
    private MediaMtxClient mediaMtx;
    @Mock
    private StreamEventService events;
    @Mock
    private StreamCommandPublisher publisher;

    private DeviceStreamRow running(UUID streamId, UUID deviceId) {
        return new DeviceStreamRow(
            streamId, deviceId, "RUNNING", Instant.now().plusSeconds(120), null, null);
    }

    @Test
    void disabledWhenApiUrlIsBlank() {
        var worker = new StreamMediaReconcileWorker(
            mapper, mediaMtx, events, publisher, new MediaMtxProperties("", "live", 2));

        worker.reconcile();

        verifyNoInteractions(mapper, mediaMtx, events, publisher);
    }

    @Test
    void failsStreamOnlyAfterConsecutiveMisses() {
        UUID streamId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findRunningStreams()).thenReturn(List.of(running(streamId, deviceId)));
        when(mediaMtx.pathState("live/" + streamId)).thenReturn(PathState.NOT_READY);
        var worker = new StreamMediaReconcileWorker(mapper, mediaMtx, events, publisher, ENABLED);

        worker.reconcile();
        verify(events, never()).failed(deviceId, streamId, StreamMediaReconcileWorker.FAILURE_CODE);

        worker.reconcile();
        verify(events).failed(deviceId, streamId, StreamMediaReconcileWorker.FAILURE_CODE);
        verify(publisher).stop(deviceId, streamId, StreamMediaReconcileWorker.FAILURE_CODE);
    }

    @Test
    void readyResetsMissCounter() {
        UUID streamId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findRunningStreams()).thenReturn(List.of(running(streamId, deviceId)));
        when(mediaMtx.pathState("live/" + streamId))
            .thenReturn(PathState.NOT_READY, PathState.READY, PathState.NOT_READY);
        var worker = new StreamMediaReconcileWorker(mapper, mediaMtx, events, publisher, ENABLED);

        worker.reconcile();
        worker.reconcile();
        worker.reconcile();

        verify(events, never()).failed(deviceId, streamId, StreamMediaReconcileWorker.FAILURE_CODE);
    }

    @Test
    void unknownApiStateNeverKillsSessions() {
        UUID streamId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findRunningStreams()).thenReturn(List.of(running(streamId, deviceId)));
        when(mediaMtx.pathState("live/" + streamId)).thenReturn(PathState.UNKNOWN);
        var worker = new StreamMediaReconcileWorker(mapper, mediaMtx, events, publisher, ENABLED);

        worker.reconcile();
        worker.reconcile();
        worker.reconcile();

        verifyNoInteractions(events, publisher);
    }
}
