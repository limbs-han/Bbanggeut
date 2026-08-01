package com.wj.server.stream.application;

import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

import com.wj.server.audit.application.AuditService;
import com.wj.server.common.api.ApiException;
import com.wj.server.config.StreamProperties;
import com.wj.server.config.DemoProperties;
import com.wj.server.iot.telemetry.DevicePresenceStore;
import com.wj.server.stream.api.StreamSessionResponse;
import com.wj.server.stream.api.TalkbackResponse;
import com.wj.server.stream.domain.DeviceStreamRow;
import com.wj.server.stream.domain.StreamSessionRow;
import com.wj.server.stream.domain.TalkbackRow;
import com.wj.server.stream.persistence.StreamMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class StreamService {
    private final StreamMapper mapper;
    private final StreamCommandPublisher publisher;
    private final LiveTokenService liveTokenService;
    private final StreamProperties properties;
    private final AuditService auditService;
    private final Clock clock;
    private final DemoProperties demoProperties;
    private final DevicePresenceStore presenceStore;

    @Autowired
    public StreamService(
        StreamMapper mapper,
        StreamCommandPublisher publisher,
        LiveTokenService liveTokenService,
        StreamProperties properties,
        AuditService auditService,
        DemoProperties demoProperties,
        DevicePresenceStore presenceStore
    ) {
        this(mapper, publisher, liveTokenService, properties, auditService,
            demoProperties, presenceStore, Clock.systemUTC());
    }

    StreamService(
        StreamMapper mapper,
        StreamCommandPublisher publisher,
        LiveTokenService liveTokenService,
        StreamProperties properties,
        AuditService auditService,
        DemoProperties demoProperties,
        DevicePresenceStore presenceStore,
        Clock clock
    ) {
        this.mapper = mapper;
        this.publisher = publisher;
        this.liveTokenService = liveTokenService;
        this.properties = properties;
        this.auditService = auditService;
        this.demoProperties = demoProperties;
        this.presenceStore = presenceStore;
        this.clock = clock;
    }

    @Transactional
    public StreamSessionResponse create(UUID userId, UUID deviceId) {
        mapper.findActiveRole(userId, deviceId).orElseThrow(this::notFound);
        DevicePresenceStore.Lookup presence = presenceStore.find(deviceId);
        boolean online = presence.storeAvailable()
            ? presence.online()
            : "ONLINE".equals(
                mapper.findAccessibleDeviceStatus(userId, deviceId).orElseThrow(this::notFound));
        if (!online) {
            throw new ApiException(HttpStatus.CONFLICT, "DEVICE_OFFLINE", "온라인 기기만 실시간 보기를 시작할 수 있습니다.");
        }
        mapper.lockDevice(deviceId);
        mapper.expireStaleSessions();
        mapper.scheduleStopsWithoutViewers(properties.idleTimeout().toMillis());

        Instant now = clock.instant();
        Instant hardExpiresAt = now.plus(properties.edgeLease());
        DeviceStreamRow stream = mapper.findReusableStream(deviceId).orElse(null);
        boolean newStream = stream == null;
        UUID streamId;
        String sessionStatus;
        if (newStream) {
            streamId = UUID.randomUUID();
            mapper.insertStream(streamId, deviceId, hardExpiresAt);
            sessionStatus = "PENDING";
        } else {
            streamId = stream.id();
            mapper.reuseStream(streamId, hardExpiresAt);
            boolean reusableSourceWasReady = "RUNNING".equals(stream.status())
                || "STOP_PENDING".equals(stream.status());
            // A RUNNING database row does not prove that the edge publisher
            // survived a reboot or network loss. Production viewers wait for
            // a fresh idempotent START/READY handshake before receiving WHEP.
            sessionStatus = demoProperties.enabled() && reusableSourceWasReady
                ? "READY" : "PENDING";
        }

        UUID sessionId = UUID.randomUUID();
        mapper.insertSession(
            sessionId, streamId, deviceId, userId, sessionStatus,
            now, now.plus(properties.viewerTtl()));
        if (demoProperties.enabled()) {
            if (newStream) {
                mapper.markStreamReady(deviceId, streamId, hardExpiresAt);
                mapper.markSessionsReady(streamId);
            }
        } else if (!publisher.start(deviceId, sessionId, streamId, hardExpiresAt)) {
            mapper.markStreamFailed(deviceId, streamId, "MQTT_PUBLISH_FAILED");
            mapper.markSessionsFailed(streamId, "MQTT_PUBLISH_FAILED");
        }
        StreamSessionRow row = mapper.findAccessibleSession(userId, sessionId).orElseThrow(this::notFound);
        auditService.success(deviceId, userId, "STREAM_OPEN", "STREAM_SESSION", sessionId);
        return toResponse(row);
    }

    @Transactional
    public StreamSessionResponse get(UUID userId, UUID sessionId) {
        expireAndScheduleStops();
        return mapper.findAccessibleSession(userId, sessionId).map(this::toResponse).orElseThrow(this::notFound);
    }

    @Transactional
    public void heartbeat(UUID userId, UUID sessionId) {
        StreamSessionRow session = mapper.findAccessibleSession(userId, sessionId).orElseThrow(this::notFound);
        Instant now = clock.instant();
        if (mapper.heartbeatSession(sessionId, userId, now, now.plus(properties.viewerTtl())) != 1) {
            expireAndScheduleStops();
            throw notFound();
        }
        Instant hardExpiresAt = now.plus(properties.edgeLease());
        mapper.extendStream(session.streamId(), hardExpiresAt);
        // 발화 중인 세션의 heartbeat는 발화 권한도 함께 연장한다. 별도 API를
        // 두면 앱이 두 주기를 따로 관리해야 하고, 한쪽만 실패했을 때 권한이
        // 남아 다른 구성원이 영영 말하지 못하게 된다.
        mapper.extendTalkback(session.deviceId(), sessionId, now.plus(properties.talkbackTtl()));
        if ("PENDING".equals(session.status())) {
            // START_STREAM is an at-least-once command. If its first MQTT
            // delivery was missed, keep the session recoverable instead of
            // sending EXTEND_STREAM to an edge process that never started.
            publisher.start(
                session.deviceId(), session.id(), session.streamId(), hardExpiresAt);
        } else {
            publisher.extend(session.deviceId(), session.streamId(), hardExpiresAt);
        }
        auditService.success(session.deviceId(), userId, "STREAM_HEARTBEAT", "STREAM_SESSION", sessionId);
    }

    @Transactional
    public void close(UUID userId, UUID sessionId) {
        StreamSessionRow session = mapper.findAccessibleSession(userId, sessionId).orElseThrow(this::notFound);
        // 라이브를 닫으면 발화 권한도 함께 놓는다. 그러지 않으면 만료될 때까지
        // 기기가 마이크를 닫지 못하고 다른 구성원도 말할 수 없다.
        releaseTalkback(session, "VIEWER_CLOSED");
        if ("PENDING".equals(session.status()) || "READY".equals(session.status())) {
            mapper.closeSession(sessionId, userId, clock.instant());
            mapper.scheduleStopsWithoutViewers(properties.idleTimeout().toMillis());
        }
        auditService.success(session.deviceId(), userId, "STREAM_CLOSE", "STREAM_SESSION", sessionId);
    }

    /**
     * 앱이 기기 스피커로 말할 수 있도록 발화 권한을 얻고 WHIP 송출 URL을 발급한다.
     * 기기에는 에코 제거가 없으므로 앱이 발화하는 동안 자신의 재생을 뮤트해
     * 스피커에서 마이크로 돌아오는 순환을 끊는다. 기기당 발화자는 한 명이다.
     */
    @Transactional
    public TalkbackResponse openTalkback(UUID userId, UUID sessionId) {
        StreamSessionRow session = mapper.findAccessibleSession(userId, sessionId).orElseThrow(this::notFound);
        Instant now = clock.instant();
        if (!"READY".equals(session.status()) || !session.viewerExpiresAt().isAfter(now)) {
            throw new ApiException(
                HttpStatus.CONFLICT, "STREAM_NOT_READY", "실시간 영상이 준비된 뒤에 말할 수 있습니다.");
        }

        mapper.lockDevice(session.deviceId());
        Instant expiresAt = now.plus(properties.talkbackTtl());
        TalkbackRow talkback = mapper
            .acquireTalkback(session.deviceId(), sessionId, session.streamId(), userId, expiresAt)
            .orElseThrow(() -> new ApiException(
                HttpStatus.CONFLICT, "TALKBACK_BUSY", "다른 구성원이 말하는 중입니다."));

        if (!demoProperties.enabled()
            && !publisher.startTalkback(session.deviceId(), session.streamId(), expiresAt)) {
            mapper.releaseTalkback(session.deviceId(), sessionId);
            throw new ApiException(
                HttpStatus.SERVICE_UNAVAILABLE, "MQTT_PUBLISH_FAILED", "기기에 명령을 전달하지 못했습니다.");
        }

        auditService.success(session.deviceId(), userId, "TALKBACK_OPEN", "STREAM_SESSION", sessionId);
        String token = liveTokenService.issue(
            sessionId, userId, session.deviceId(), session.streamId(), LiveTokenService.Scope.TALK);
        String whipUrl = properties.talkbackWhipBaseUrl().replaceAll("/$", "")
            + "/" + session.streamId() + "/whip?token=" + token;
        return new TalkbackResponse(
            sessionId, session.streamId(), session.deviceId(), whipUrl,
            Math.toIntExact(properties.heartbeatInterval().toSeconds()), talkback.expiresAt());
    }

    @Transactional
    public void closeTalkback(UUID userId, UUID sessionId) {
        StreamSessionRow session = mapper.findAccessibleSession(userId, sessionId).orElseThrow(this::notFound);
        releaseTalkback(session, "VIEWER_RELEASED");
        auditService.success(session.deviceId(), userId, "TALKBACK_CLOSE", "STREAM_SESSION", sessionId);
    }

    private void releaseTalkback(StreamSessionRow session, String reason) {
        mapper.releaseTalkback(session.deviceId(), session.id()).ifPresent(released -> {
            if (!demoProperties.enabled()) {
                publisher.stopTalkback(session.deviceId(), released.streamId(), reason);
            }
        });
    }

    @Transactional(readOnly = true)
    public boolean introspect(String token, UUID streamId, LiveTokenService.Scope scope) {
        LiveTokenService.Claims claims = liveTokenService.verify(token);
        if (claims == null || !streamId.equals(claims.streamId()) || claims.scope() != scope) {
            return false;
        }
        return scope == LiveTokenService.Scope.TALK
            ? mapper.isTalkable(claims.sessionId(), claims.userId())
            : mapper.isPlayable(claims.sessionId(), claims.userId());
    }

    private void expireAndScheduleStops() {
        mapper.expireStaleSessions();
        mapper.scheduleStopsWithoutViewers(properties.idleTimeout().toMillis());
    }

    private StreamSessionResponse toResponse(StreamSessionRow row) {
        String whepUrl = null;
        if ("READY".equals(row.status()) && row.viewerExpiresAt().isAfter(clock.instant())) {
            String token = liveTokenService.issue(row.id(), row.userId(), row.deviceId(), row.streamId());
            String configuredDemoWhepUrl = demoProperties.liveWhepUrl();
            boolean explicitDemoWhepUrl = demoProperties.enabled()
                && configuredDemoWhepUrl != null && !configuredDemoWhepUrl.isBlank();
            String whepBaseUrl = explicitDemoWhepUrl
                ? configuredDemoWhepUrl
                : properties.webrtcBaseUrl().replaceAll("/$", "") + "/" + row.streamId() + "/whep";
            if (explicitDemoWhepUrl) {
                whepBaseUrl += (whepBaseUrl.contains("?") ? "&" : "?") + "streamId=" + row.streamId();
            }
            whepUrl = whepBaseUrl + (whepBaseUrl.contains("?") ? "&" : "?") + "token=" + token;
        }
        return new StreamSessionResponse(
            row.id(), row.streamId(), row.deviceId(), row.status(), whepUrl,
            Math.toIntExact(properties.heartbeatInterval().toSeconds()),
            row.viewerExpiresAt(), row.edgeHardExpiresAt(), row.failureCode(), row.createdAt());
    }

    private ApiException notFound() {
        return new ApiException(HttpStatus.NOT_FOUND, "RESOURCE_NOT_FOUND", "리소스를 찾을 수 없습니다.");
    }
}
