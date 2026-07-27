package com.wj.server.stream.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.StreamProperties;
import com.wj.server.config.DemoProperties;
import com.wj.server.stream.domain.DeviceStreamRow;
import com.wj.server.stream.domain.StreamSessionRow;
import com.wj.server.stream.persistence.StreamMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class StreamServiceTest {
    private static final Instant NOW = Instant.parse("2026-07-17T10:00:00Z");
    @Mock private StreamMapper mapper;
    @Mock private StreamCommandPublisher publisher;
    @Mock private LiveTokenService liveTokenService;
    @Mock private AuditService auditService;
    private StreamService service;

    @BeforeEach
    void setUp() {
        StreamProperties properties = new StreamProperties(
            Duration.ofSeconds(45), Duration.ofSeconds(60), Duration.ofSeconds(120),
            Duration.ofSeconds(15), "https://media.example/live/", Duration.ofSeconds(30));
        service = new StreamService(mapper, publisher, liveTokenService, properties, auditService,
            new DemoProperties(false, null),
            Clock.fixed(NOW, ZoneOffset.UTC));
    }

    @Test
    void createsPendingSessionAndPublishesStartForOnlineDevice() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findActiveRole(userId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(mapper.findAccessibleDeviceStatus(userId, deviceId)).thenReturn(Optional.of("ONLINE"));
        when(mapper.findReusableStream(deviceId)).thenReturn(Optional.empty());
        when(publisher.start(eq(deviceId), any(), any(), eq(NOW.plusSeconds(120)))).thenReturn(true);
        when(mapper.findAccessibleSession(eq(userId), any())).thenAnswer(invocation -> {
            UUID sessionId = invocation.getArgument(1);
            return Optional.of(row(sessionId, UUID.randomUUID(), deviceId, userId, "PENDING"));
        });

        var response = service.create(userId, deviceId);

        assertThat(response.status()).isEqualTo("PENDING");
        verify(publisher).start(eq(deviceId), eq(response.sessionId()), any(), eq(NOW.plusSeconds(120)));
    }

    @Test
    void reusesRunningDeviceStreamOnlyAfterFreshEdgeHandshake() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID streamId = UUID.randomUUID();
        when(mapper.findActiveRole(userId, deviceId)).thenReturn(Optional.of("VIEWER"));
        when(mapper.findAccessibleDeviceStatus(userId, deviceId)).thenReturn(Optional.of("ONLINE"));
        when(mapper.findReusableStream(deviceId)).thenReturn(Optional.of(
            new DeviceStreamRow(streamId, deviceId, "RUNNING", NOW.plusSeconds(80), null, null)));
        when(publisher.start(eq(deviceId), any(), eq(streamId), eq(NOW.plusSeconds(120))))
            .thenReturn(true);
        when(mapper.findAccessibleSession(eq(userId), any())).thenAnswer(invocation -> Optional.of(
            row(invocation.getArgument(1), streamId, deviceId, userId, "PENDING")));

        var response = service.create(userId, deviceId);

        assertThat(response.streamId()).isEqualTo(streamId);
        assertThat(response.status()).isEqualTo("PENDING");
        assertThat(response.playUrl()).isNull();
        verify(publisher).start(deviceId, response.sessionId(), streamId, NOW.plusSeconds(120));
    }

    @Test
    void demoWithoutExplicitHlsUrlUsesTheTokenProtectedStreamPath() {
        StreamProperties properties = new StreamProperties(
            Duration.ofSeconds(45), Duration.ofSeconds(60), Duration.ofSeconds(120),
            Duration.ofSeconds(15), "https://media.example/live/", Duration.ofSeconds(30));
        service = new StreamService(mapper, publisher, liveTokenService, properties, auditService,
            new DemoProperties(true, ""), Clock.fixed(NOW, ZoneOffset.UTC));
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID streamId = UUID.randomUUID();
        when(mapper.findActiveRole(userId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(mapper.findAccessibleDeviceStatus(userId, deviceId)).thenReturn(Optional.of("ONLINE"));
        when(mapper.findReusableStream(deviceId)).thenReturn(Optional.of(
            new DeviceStreamRow(streamId, deviceId, "RUNNING", NOW.plusSeconds(80), null, null)));
        when(mapper.findAccessibleSession(eq(userId), any())).thenAnswer(invocation -> Optional.of(
            row(invocation.getArgument(1), streamId, deviceId, userId, "READY")));
        when(liveTokenService.issue(any(), eq(userId), eq(deviceId), eq(streamId))).thenReturn("live-token");

        var response = service.create(userId, deviceId);

        assertThat(response.playUrl())
            .isEqualTo("https://media.example/live/" + streamId + "/index.m3u8?token=live-token");
    }

    @Test
    void rejectsOfflineDevice() {
        UUID userId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        when(mapper.findActiveRole(userId, deviceId)).thenReturn(Optional.of("OWNER"));
        when(mapper.findAccessibleDeviceStatus(userId, deviceId)).thenReturn(Optional.of("OFFLINE"));

        assertThatThrownBy(() -> service.create(userId, deviceId))
            .isInstanceOf(ApiException.class)
            .extracting(error -> ((ApiException) error).code())
            .isEqualTo("DEVICE_OFFLINE");
    }

    @Test
    void introspectionBindsTokenToRequestedStream() {
        UUID sessionId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        UUID signedStreamId = UUID.randomUUID();
        when(liveTokenService.verify("token"))
            .thenReturn(new LiveTokenService.Claims(sessionId, userId, signedStreamId));
        when(mapper.isPlayable(sessionId, userId)).thenReturn(true);

        assertThat(service.introspect("token", signedStreamId)).isTrue();
        assertThat(service.introspect("token", UUID.randomUUID())).isFalse();
    }

    @Test
    void heartbeatRetriesStartWhileSessionIsPending() {
        UUID sessionId = UUID.randomUUID();
        UUID streamId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        when(mapper.findAccessibleSession(userId, sessionId))
            .thenReturn(Optional.of(row(sessionId, streamId, deviceId, userId, "PENDING")));
        when(mapper.heartbeatSession(
            sessionId, userId, NOW, NOW.plusSeconds(45))).thenReturn(1);

        service.heartbeat(userId, sessionId);

        verify(publisher).start(
            deviceId, sessionId, streamId, NOW.plusSeconds(120));
        verify(publisher, never()).extend(any(), any(), any());
    }

    @Test
    void heartbeatExtendsAnAlreadyReadyStream() {
        UUID sessionId = UUID.randomUUID();
        UUID streamId = UUID.randomUUID();
        UUID deviceId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        when(mapper.findAccessibleSession(userId, sessionId))
            .thenReturn(Optional.of(row(sessionId, streamId, deviceId, userId, "READY")));
        when(mapper.heartbeatSession(
            sessionId, userId, NOW, NOW.plusSeconds(45))).thenReturn(1);

        service.heartbeat(userId, sessionId);

        verify(publisher).extend(deviceId, streamId, NOW.plusSeconds(120));
        verify(publisher, never()).start(any(), any(), any(), any());
    }

    private StreamSessionRow row(
        UUID sessionId, UUID streamId, UUID deviceId, UUID userId, String status
    ) {
        return new StreamSessionRow(
            sessionId, streamId, deviceId, userId, status, NOW,
            NOW.plusSeconds(45), NOW.plusSeconds(120), null, NOW);
    }
}
