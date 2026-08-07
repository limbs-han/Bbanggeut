package com.wj.server.device.application;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class RegistrationCodeHasherTest {
    private final RegistrationCodeHasher hasher = new RegistrationCodeHasher();

    @Test
    void codeIsTrimmedCaseInsensitiveAndHyphenFree() {
        String hash = hasher.hash("  7f3k-9xqm  ");

        assertThat(hasher.matches("7F3K9XQM", hash)).isTrue();
        assertThat(hasher.matches("7F3K-9XQM", hash)).isTrue();
        assertThat(hasher.matches("7F3K-9999", hash)).isFalse();
        assertThat(hash).matches("[0-9a-f]{64}");
    }

    @Test
    void ambiguousCharactersFoldOntoCanonicalAlphabet() {
        String hash = hasher.hash("0123ABCD");

        // O is not in the display alphabet; user input folds O->0, I/L->1.
        assertThat(hasher.matches("O123ABCD", hash)).isTrue();
        assertThat(hasher.matches("0I23ABCD", hash)).isTrue();
        assertThat(hasher.matches("0L23ABCD", hash)).isTrue();
    }
}
