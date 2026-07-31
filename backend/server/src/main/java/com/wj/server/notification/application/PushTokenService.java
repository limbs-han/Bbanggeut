package com.wj.server.notification.application;

import java.util.UUID;

import com.wj.server.notification.api.RegisterPushTokenRequest;
import com.wj.server.notification.persistence.PushTokenMapper;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class PushTokenService {
    private final PushTokenMapper mapper;

    public PushTokenService(PushTokenMapper mapper) {
        this.mapper = mapper;
    }

    @Transactional
    public void register(UUID userId, RegisterPushTokenRequest request) {
        mapper.deleteTokenFromOtherInstallation(
            userId, request.installationId(), request.token());
        mapper.upsert(
            UUID.randomUUID(), userId, request.installationId(),
            request.token(), request.platform());
    }

    @Transactional
    public void unregister(UUID userId, String installationId) {
        mapper.deleteForUser(userId, installationId);
    }
}
