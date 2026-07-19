package com.wj.server.device.application;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;
import java.util.Locale;

import org.springframework.stereotype.Component;

@Component
public class ProductCodeHasher {

    public String hash(String productCode) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest(normalize(productCode).getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    public boolean matches(String productCode, String expectedHash) {
        return MessageDigest.isEqual(
            hash(productCode).getBytes(StandardCharsets.US_ASCII),
            expectedHash.getBytes(StandardCharsets.US_ASCII));
    }

    private String normalize(String productCode) {
        return productCode.trim().toUpperCase(Locale.ROOT);
    }
}
