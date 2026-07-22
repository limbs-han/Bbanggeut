package com.wj.server.iot.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

import java.security.MessageDigest;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Optional;
import java.util.UUID;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class DeviceCredentialAuthenticatorTest {
    @Mock
    private DeviceCredentialMapper mapper;

    @Test
    void authenticatesActiveDeviceTokenAndRejectsWrongSecret() throws Exception {
        UUID deviceId = UUID.randomUUID();
        String secret = "device-secret-at-least-thirty-two-characters";
        String hash = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
            .digest(secret.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        when(mapper.findActiveToken("device-key")).thenReturn(Optional.of(
            new DeviceCredentialRow(
                deviceId, "device-key", hash, "ACTIVE", Instant.now().plusSeconds(60), "OFFLINE", "OPERATING")));
        DeviceCredentialAuthenticator authenticator = new DeviceCredentialAuthenticator(mapper);

        assertThat(authenticator.authenticate("device-key." + secret))
            .contains(new DevicePrincipal(deviceId, "device-key", "OPERATING"));
        assertThat(authenticator.authenticate("device-key." + "x".repeat(40))).isEmpty();
    }
}
