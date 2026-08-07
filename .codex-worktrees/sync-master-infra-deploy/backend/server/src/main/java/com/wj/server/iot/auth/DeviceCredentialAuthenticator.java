package com.wj.server.iot.auth;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Optional;

import org.springframework.stereotype.Service;

@Service
public class DeviceCredentialAuthenticator {
    private final DeviceCredentialMapper mapper;

    public DeviceCredentialAuthenticator(DeviceCredentialMapper mapper) {
        this.mapper = mapper;
    }

    public Optional<DevicePrincipal> authenticate(String token) {
        int separator = token.indexOf('.');
        if (separator < 1 || separator == token.length() - 1) {
            return Optional.empty();
        }
        String keyId = token.substring(0, separator);
        String secret = token.substring(separator + 1);
        if (keyId.length() > 100 || secret.length() < 32 || secret.length() > 512) {
            return Optional.empty();
        }
        return mapper.findActiveToken(keyId)
            .filter(row -> constantTimeEquals(hash(secret), row.secretHash()))
            .map(row -> new DevicePrincipal(row.deviceId(), row.keyId(), row.purpose()));
    }

    private String hash(String value) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    private boolean constantTimeEquals(String actual, String expected) {
        return MessageDigest.isEqual(
            actual.getBytes(StandardCharsets.US_ASCII),
            expected.getBytes(StandardCharsets.US_ASCII));
    }
}
