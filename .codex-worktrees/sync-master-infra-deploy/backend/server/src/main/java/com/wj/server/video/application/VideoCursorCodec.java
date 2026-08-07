package com.wj.server.video.application;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Base64;
import java.util.UUID;

import com.wj.server.common.api.ApiException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

@Component
public class VideoCursorCodec {

    public String encode(Instant createdAt, UUID id) {
        String value = createdAt.toEpochMilli() + ":" + id;
        return Base64.getUrlEncoder().withoutPadding()
            .encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    public Cursor decode(String cursor) {
        if (cursor == null || cursor.isBlank()) {
            return new Cursor(null, null);
        }
        if (cursor.length() > 500) {
            throw invalidCursor();
        }
        try {
            String decoded = new String(
                Base64.getUrlDecoder().decode(cursor), StandardCharsets.UTF_8);
            int separator = decoded.indexOf(':');
            if (separator < 1) {
                throw invalidCursor();
            }
            return new Cursor(
                Instant.ofEpochMilli(Long.parseLong(decoded.substring(0, separator))),
                UUID.fromString(decoded.substring(separator + 1)));
        } catch (IllegalArgumentException exception) {
            throw invalidCursor();
        }
    }

    private ApiException invalidCursor() {
        return new ApiException(
            HttpStatus.UNPROCESSABLE_ENTITY, "INVALID_CURSOR", "페이지 커서가 유효하지 않습니다.");
    }

    public record Cursor(Instant createdAt, UUID id) {
    }
}
