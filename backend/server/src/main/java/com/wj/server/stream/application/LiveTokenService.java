package com.wj.server.stream.application;

import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

import com.wj.server.config.StreamProperties;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.oauth2.jose.jws.MacAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.stereotype.Component;

@Component
public class LiveTokenService {
    private final JwtEncoder encoder;
    private final JwtDecoder decoder;
    private final StreamProperties properties;
    private final Clock clock;

    @Autowired
    public LiveTokenService(JwtEncoder encoder, JwtDecoder decoder, StreamProperties properties) {
        this(encoder, decoder, properties, Clock.systemUTC());
    }

    LiveTokenService(JwtEncoder encoder, JwtDecoder decoder, StreamProperties properties, Clock clock) {
        this.encoder = encoder;
        this.decoder = decoder;
        this.properties = properties;
        this.clock = clock;
    }

    public String issue(UUID sessionId, UUID userId, UUID deviceId, UUID streamId) {
        return issue(sessionId, userId, deviceId, streamId, Scope.PLAY);
    }

    public String issue(UUID sessionId, UUID userId, UUID deviceId, UUID streamId, Scope scope) {
        Instant now = clock.instant();
        JwtClaimsSet claims = JwtClaimsSet.builder()
            .issuer("wj-live")
            .subject(userId.toString())
            .issuedAt(now)
            .expiresAt(now.plus(properties.liveTokenTtl()))
            .claim("typ", "live")
            .claim("sessionId", sessionId.toString())
            .claim("deviceId", deviceId.toString())
            .claim("streamId", streamId.toString())
            .claim("scope", scope.name())
            .build();
        return encoder.encode(JwtEncoderParameters.from(
            JwsHeader.with(MacAlgorithm.HS256).build(), claims)).getTokenValue();
    }

    public Claims verify(String token) {
        try {
            var jwt = decoder.decode(token);
            if (!"wj-live".equals(jwt.getClaimAsString("iss"))
                || !"live".equals(jwt.getClaimAsString("typ"))) {
                return null;
            }
            Scope scope = Scope.parse(jwt.getClaimAsString("scope"));
            if (scope == null) {
                return null;
            }
            return new Claims(
                UUID.fromString(jwt.getClaimAsString("sessionId")),
                UUID.fromString(jwt.getSubject()),
                UUID.fromString(jwt.getClaimAsString("streamId")),
                scope);
        } catch (RuntimeException exception) {
            return null;
        }
    }

    /**
     * WHEP 재생과 WHIP 발화는 권한 판정이 다르다. 재생 토큰으로 기기 스피커에
     * 송출할 수 없도록 토큰 자체에 용도를 새긴다.
     */
    public enum Scope {
        PLAY,
        TALK;

        /**
         * {@code scope}가 없는 토큰은 이 클레임 도입 이전에 발급된 재생 토큰이다.
         * 만료 시간이 짧아 곧 사라지므로 PLAY로 해석한다.
         */
        public static Scope parse(String value) {
            if (value == null || value.isBlank()) {
                return PLAY;
            }
            for (Scope scope : values()) {
                if (scope.name().equals(value)) {
                    return scope;
                }
            }
            return null;
        }
    }

    public record Claims(UUID sessionId, UUID userId, UUID streamId, Scope scope) {
    }
}
