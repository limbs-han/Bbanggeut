package com.wj.server.device.application;

import java.security.SecureRandom;

import org.springframework.stereotype.Component;

@Component
public class RegistrationCodeGenerator {
    // Crockford Base32: digits and uppercase letters without I, L, O, U.
    static final String ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    static final int LENGTH = 8;

    private final SecureRandom random = new SecureRandom();

    /** Returns the canonical 8-character code without the display hyphen. */
    public String generate() {
        StringBuilder code = new StringBuilder(LENGTH);
        for (int i = 0; i < LENGTH; i++) {
            code.append(ALPHABET.charAt(random.nextInt(ALPHABET.length())));
        }
        return code.toString();
    }

    /** Formats a canonical code as XXXX-XXXX for the device screen. */
    public String display(String code) {
        return code.substring(0, 4) + "-" + code.substring(4);
    }
}
