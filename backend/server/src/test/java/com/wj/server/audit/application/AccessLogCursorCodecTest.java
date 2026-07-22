package com.wj.server.audit.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;

import com.wj.server.common.api.ApiException;
import org.junit.jupiter.api.Test;

class AccessLogCursorCodecTest {
    private final AccessLogCursorCodec codec = new AccessLogCursorCodec();

    @Test
    void roundTripsTimestampAndIdentity() {
        Instant createdAt = Instant.parse("2026-07-17T10:00:00.123Z");

        var decoded = codec.decode(codec.encode(createdAt, 42));

        assertThat(decoded.createdAt()).isEqualTo(createdAt);
        assertThat(decoded.id()).isEqualTo(42L);
    }

    @Test
    void rejectsMalformedCursor() {
        assertThatThrownBy(() -> codec.decode("not-a-cursor"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("INVALID_CURSOR");
    }
}
