package com.wj.server.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.time.Duration;
import java.util.Optional;
import java.util.UUID;

import com.wj.server.auth.application.AccessTokenValidator;
import com.wj.server.auth.application.JwtTokenService;
import com.wj.server.auth.domain.SessionAuthStateRow;
import com.wj.server.auth.domain.UserRow;
import com.wj.server.auth.persistence.AuthMapper;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtValidationException;

/**
 * Two decoders share one signing key: the primary one checks signature and
 * expiry for live-stream tokens, while the user API's decoder additionally
 * demands a live session. The split only holds together at wiring time, so it
 * is exercised here end to end over a real signed token.
 */
class JwtConfigWiringTest {
    private static final UUID USER_ID = UUID.fromString("11111111-1111-1111-1111-111111111111");
    private static final UUID SESSION_ID = UUID.fromString("22222222-2222-2222-2222-222222222222");
    private static final AuthProperties PROPERTIES = new AuthProperties(
        Duration.ofMinutes(15),
        Duration.ofDays(14),
        "test-signing-key-that-is-long-enough-1234567890",
        5,
        Duration.ofMinutes(10));

    private final AuthMapper authMapper = mock(AuthMapper.class);

    @Test
    void userApiDecoderRejectsATokenWhoseSessionWasRevoked() {
        when(authMapper.findSessionAuthState(SESSION_ID)).thenReturn(Optional.empty());

        contextRunner().run(context -> {
            assertThat(context).hasNotFailed();
            String token = accessToken(context.getBean(JwtEncoder.class));

            assertThatThrownBy(() -> accessTokenDecoder(context).decode(token))
                .isInstanceOf(JwtValidationException.class);
            // Same signature, same expiry — only the session check differs.
            assertThat(context.getBean(JwtDecoder.class).decode(token).getSubject())
                .isEqualTo(USER_ID.toString());
        });
    }

    @Test
    void userApiDecoderAcceptsATokenWhoseSessionIsStillLive() {
        when(authMapper.findSessionAuthState(SESSION_ID))
            .thenReturn(Optional.of(new SessionAuthStateRow(USER_ID, 0, "ACTIVE")));

        contextRunner().run(context -> {
            String token = accessToken(context.getBean(JwtEncoder.class));

            assertThat(accessTokenDecoder(context).decode(token).getClaimAsString("sid"))
                .isEqualTo(SESSION_ID.toString());
        });
    }

    private ApplicationContextRunner contextRunner() {
        return new ApplicationContextRunner()
            .withUserConfiguration(JwtConfig.class, AccessTokenValidator.class)
            .withBean(AuthProperties.class, () -> PROPERTIES)
            .withBean(AuthMapper.class, () -> authMapper);
    }

    private JwtDecoder accessTokenDecoder(org.springframework.context.ApplicationContext context) {
        return context.getBean("accessTokenJwtDecoder", JwtDecoder.class);
    }

    private String accessToken(JwtEncoder encoder) {
        UserRow user = new UserRow(USER_ID, "user@example.com", "hash", "tester", "ACTIVE", 0);
        return new JwtTokenService(encoder, PROPERTIES).createAccessToken(user, SESSION_ID);
    }
}
