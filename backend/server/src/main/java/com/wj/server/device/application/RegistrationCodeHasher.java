package com.wj.server.device.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Locale;

import org.springframework.stereotype.Component;

@Component
public class RegistrationCodeHasher {

    public String hash(String registrationCode) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest(normalize(registrationCode).getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    public boolean matches(String registrationCode, String expectedHash) {
        return MessageDigest.isEqual(
            hash(registrationCode).getBytes(StandardCharsets.US_ASCII),
            expectedHash.getBytes(StandardCharsets.US_ASCII));
    }

    // The display alphabet excludes O/I/L/U, so ambiguous user input can be
    // folded onto the canonical characters before hashing.
    private String normalize(String registrationCode) {
        return registrationCode.trim()
            .toUpperCase(Locale.ROOT)
            .replace("-", "")
            .replace(" ", "")
            .replace('O', '0')
            .replace('I', '1')
            .replace('L', '1');
    }
}
