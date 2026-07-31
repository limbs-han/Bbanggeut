package com.wj.server.auth.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.Optional;
import java.util.UUID;

import com.wj.server.auth.domain.SessionAuthStateRow;
import com.wj.server.auth.persistence.AuthMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;

@ExtendWith(MockitoExtension.class)
class AccessTokenValidatorTest {
    private static final UUID USER_ID = UUID.fromString("11111111-1111-1111-1111-111111111111");
    private static final UUID SESSION_ID = UUID.fromString("22222222-2222-2222-2222-222222222222");

    @Mock
    private AuthMapper authMapper;

    private AccessTokenValidator validator;

    @BeforeEach
    void setUp() {
        validator = new AccessTokenValidator(authMapper);
    }

    @Test
    void acceptsTokenBackedByLiveSession() {
        when(authMapper.findSessionAuthState(SESSION_ID))
            .thenReturn(Optional.of(new SessionAuthStateRow(USER_ID, 3, "ACTIVE")));

        assertThat(validate(accessToken(USER_ID, SESSION_ID, 3)).hasErrors()).isFalse();
    }

    @Test
    void rejectsRevokedOrExpiredSession() {
        // findSessionAuthState filters out revoked/expired rows, so it comes back empty.
        when(authMapper.findSessionAuthState(SESSION_ID)).thenReturn(Optional.empty());

        assertThat(validate(accessToken(USER_ID, SESSION_ID, 3)).hasErrors()).isTrue();
    }

    @Test
    void rejectsStaleTokenVersionAfterPasswordChange() {
        when(authMapper.findSessionAuthState(SESSION_ID))
            .thenReturn(Optional.of(new SessionAuthStateRow(USER_ID, 4, "ACTIVE")));

        assertThat(validate(accessToken(USER_ID, SESSION_ID, 3)).hasErrors()).isTrue();
    }

    @Test
    void rejectsWithdrawnUser() {
        when(authMapper.findSessionAuthState(SESSION_ID))
            .thenReturn(Optional.of(new SessionAuthStateRow(USER_ID, 3, "WITHDRAWN")));

        assertThat(validate(accessToken(USER_ID, SESSION_ID, 3)).hasErrors()).isTrue();
    }

    @Test
    void rejectsSessionBelongingToAnotherUser() {
        when(authMapper.findSessionAuthState(SESSION_ID))
            .thenReturn(Optional.of(new SessionAuthStateRow(UUID.randomUUID(), 3, "ACTIVE")));

        assertThat(validate(accessToken(USER_ID, SESSION_ID, 3)).hasErrors()).isTrue();
    }

    @Test
    void rejectsLiveStreamTokenReplayedAgainstUserApi() {
        Jwt liveToken = Jwt.withTokenValue("token")
            .header("alg", "HS256")
            .claim("iss", "wj-live")
            .claim("typ", "live")
            .subject(USER_ID.toString())
            .claim("streamId", UUID.randomUUID().toString())
            .build();

        assertThat(validate(liveToken).hasErrors()).isTrue();
        verify(authMapper, never()).findSessionAuthState(SESSION_ID);
    }

    @Test
    void rejectsTokenWithoutSessionClaim() {
        Jwt token = Jwt.withTokenValue("token")
            .header("alg", "HS256")
            .claim("iss", JwtTokenService.ISSUER)
            .subject(USER_ID.toString())
            .claim("tv", 3)
            .build();

        assertThat(validate(token).hasErrors()).isTrue();
    }

    private OAuth2TokenValidatorResult validate(Jwt token) {
        return validator.validate(token);
    }

    private Jwt accessToken(UUID userId, UUID sessionId, int tokenVersion) {
        return Jwt.withTokenValue("token")
            .header("alg", "HS256")
            .claim("iss", JwtTokenService.ISSUER)
            .subject(userId.toString())
            .claim("sid", sessionId.toString())
            .claim("tv", tokenVersion)
            .build();
    }
}
