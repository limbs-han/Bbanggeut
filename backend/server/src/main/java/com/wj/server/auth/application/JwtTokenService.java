package com.wj.server.auth.application;

import java.time.Clock;
import java.time.Instant;
import java.util.UUID;

import com.wj.server.auth.domain.UserRow;
import com.wj.server.config.AuthProperties;
import org.springframework.security.oauth2.jose.jws.MacAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.stereotype.Component;
import org.springframework.beans.factory.annotation.Autowired;

@Component
public class JwtTokenService {
    private final JwtEncoder jwtEncoder;
    private final AuthProperties properties;
    private final Clock clock;

    @Autowired
    public JwtTokenService(JwtEncoder jwtEncoder, AuthProperties properties) {
        this(jwtEncoder, properties, Clock.systemUTC());
    }

    JwtTokenService(JwtEncoder jwtEncoder, AuthProperties properties, Clock clock) {
        this.jwtEncoder = jwtEncoder;
        this.properties = properties;
        this.clock = clock;
    }

    public String createAccessToken(UserRow user, UUID sessionId) {
        Instant now = clock.instant();
        JwtClaimsSet claims = JwtClaimsSet.builder()
            .issuer("wj-server")
            .issuedAt(now)
            .expiresAt(now.plus(properties.accessTokenTtl()))
            .subject(user.id().toString())
            .claim("sid", sessionId.toString())
            .claim("tv", user.tokenVersion())
            .build();
        JwsHeader header = JwsHeader.with(MacAlgorithm.HS256).build();
        return jwtEncoder.encode(JwtEncoderParameters.from(header, claims)).getTokenValue();
    }
}
