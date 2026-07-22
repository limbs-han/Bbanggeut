package com.wj.server.video.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import org.junit.jupiter.api.Test;

class VideoCursorCodecTest {
    private final VideoCursorCodec codec = new VideoCursorCodec();

    @Test
    void cursorRoundTripsCreatedAtAndId() {
        Instant createdAt = Instant.parse("2026-07-17T10:00:00.123Z");
        UUID id = UUID.randomUUID();

        var decoded = codec.decode(codec.encode(createdAt, id));

        assertThat(decoded.createdAt()).isEqualTo(createdAt);
        assertThat(decoded.id()).isEqualTo(id);
    }

    @Test
    void malformedCursorReturns422() {
        assertThatThrownBy(() -> codec.decode("not-a-cursor"))
            .isInstanceOf(ApiException.class)
            .extracting(exception -> ((ApiException) exception).code())
            .isEqualTo("INVALID_CURSOR");
    }
}
