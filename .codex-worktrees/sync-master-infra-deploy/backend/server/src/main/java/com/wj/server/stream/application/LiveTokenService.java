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
            return new Claims(
                UUID.fromString(jwt.getClaimAsString("sessionId")),
                UUID.fromString(jwt.getSubject()),
                UUID.fromString(jwt.getClaimAsString("streamId")));
        } catch (RuntimeException exception) {
            return null;
        }
    }

    public record Claims(UUID sessionId, UUID userId, UUID streamId) {
    }
}
