package com.wj.server.notification.application;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.inOrder;

import java.util.UUID;

import com.wj.server.notification.api.PushPlatform;
import com.wj.server.notification.api.RegisterPushTokenRequest;
import com.wj.server.notification.persistence.PushTokenMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class PushTokenServiceTest {
    @Mock
    private PushTokenMapper mapper;

    @Test
    void registerMovesTokenThenUpsertsInstallation() {
        UUID userId = UUID.randomUUID();
        var request = new RegisterPushTokenRequest(
            "installation-1", "fcm-token", PushPlatform.ANDROID);

        new PushTokenService(mapper).register(userId, request);

        var ordered = inOrder(mapper);
        ordered.verify(mapper).deleteTokenFromOtherInstallation(
            userId, "installation-1", "fcm-token");
        ordered.verify(mapper).upsert(
            any(UUID.class), eq(userId), eq("installation-1"), eq("fcm-token"),
            eq(PushPlatform.ANDROID));
    }
}
