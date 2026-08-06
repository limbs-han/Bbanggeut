package com.wj.server.stream.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
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
    /** 2회(유예 진입) / 4회(포기) — 운영 값과 눈금만 다르고 동작은 같다. */
    private static final MediaMtxProperties ENABLED =
        new MediaMtxProperties("http://127.0.0.1:9997", "live", 2, 4);

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
            mapper, mediaMtx, events, publisher, new MediaMtxProperties("", "live", 2, 4));

        worker.reconcile();

        verifyNoInteractions(mapper, mediaMtx, events, publisher);
    }

    @Test
    void giveUpThresholdDefaultsAboveFailureThreshold() {
        // 설정을 잘못 줘도 유예가 사라지지 않아야 한다 — 문턱이 같으면
        // 첫 판정에서 곧바로 실패로 확정된다.
        var properties = new MediaMtxProperties("http://127.0.0.1:9997", "live", 3, 3);

        assertThat(properties.missesBeforeGiveUp())
            .isGreaterThan(properties.missesBeforeFailure());
    }

    @Test
    void stalledStreamWaitsForReconnectBeforeFailing() {
        UUID streamId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findRunningStreams()).thenReturn(List.of(running(streamId, deviceId)));
        when(mediaMtx.pathState("live/" + streamId)).thenReturn(PathState.NOT_READY);
        var worker = new StreamMediaReconcileWorker(mapper, mediaMtx, events, publisher, ENABLED);

        worker.reconcile();
        verify(events, never()).reconnecting(streamId);

        // 2회 — 유예 진입. 세션은 살아 있고 실패도 STOP도 없다.
        worker.reconcile();
        verify(events).reconnecting(streamId);
        verify(events, never()).failed(deviceId, streamId, StreamMediaReconcileWorker.FAILURE_CODE);
        verifyNoInteractions(publisher);

        // 3회 — 유예 중. 같은 UPDATE를 반복하지 않는다.
        worker.reconcile();
        verify(events, times(1)).reconnecting(streamId);
        verify(events, never()).failed(deviceId, streamId, StreamMediaReconcileWorker.FAILURE_CODE);

        // 4회 — 포기. 이제 실패로 확정하고 기기에 STOP을 보낸다.
        worker.reconcile();
        verify(events).failed(deviceId, streamId, StreamMediaReconcileWorker.FAILURE_CODE);
        verify(publisher).stop(deviceId, streamId, StreamMediaReconcileWorker.FAILURE_CODE);
    }

    @Test
    void mediaReturningWithinGraceResumesViewers() {
        UUID streamId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findRunningStreams()).thenReturn(List.of(running(streamId, deviceId)));
        when(mediaMtx.pathState("live/" + streamId)).thenReturn(
            PathState.NOT_READY, PathState.NOT_READY, PathState.READY, PathState.NOT_READY);
        var worker = new StreamMediaReconcileWorker(mapper, mediaMtx, events, publisher, ENABLED);

        worker.reconcile();
        worker.reconcile();
        verify(events).reconnecting(streamId);

        worker.reconcile();
        verify(events).resumed(streamId);

        // 돌아온 뒤에는 카운터가 처음부터 다시 센다 — 한 번 더 놓쳤다고
        // 곧바로 유예로 내려가지 않는다.
        worker.reconcile();
        verify(events, times(1)).reconnecting(streamId);
        verify(events, never()).failed(deviceId, streamId, StreamMediaReconcileWorker.FAILURE_CODE);
    }

    @Test
    void healthyStreamIsNeverTouched() {
        UUID streamId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findRunningStreams()).thenReturn(List.of(running(streamId, deviceId)));
        when(mediaMtx.pathState("live/" + streamId)).thenReturn(PathState.READY);
        var worker = new StreamMediaReconcileWorker(mapper, mediaMtx, events, publisher, ENABLED);

        worker.reconcile();
        worker.reconcile();

        // 멀쩡한 세션에 15초마다 UPDATE를 날리지 않는다.
        verifyNoInteractions(events, publisher);
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
        // 유예에 들기 전에 돌아왔으므로 세션을 내린 적도, 올린 적도 없다.
        verify(events, never()).reconnecting(streamId);
        verify(events, never()).resumed(streamId);
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
