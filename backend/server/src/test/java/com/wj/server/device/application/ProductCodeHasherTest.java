package com.wj.server.device.application;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;

class ProductCodeHasherTest {
    private final ProductCodeHasher hasher = new ProductCodeHasher();

    @Test
    void productCodeIsTrimmedAndCaseInsensitive() {
        String hash = hasher.hash("  abcd-1234  ");

        assertThat(hasher.matches("ABCD-1234", hash)).isTrue();
        assertThat(hasher.matches("ABCD-9999", hash)).isFalse();
        assertThat(hash).matches("[0-9a-f]{64}");
    }
}
